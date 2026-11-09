public with sharing class CareerHubApplicationIntake {
    @AuraEnabled
    public static List<Application_Intake__c> getQueue(Boolean showCompleted) {
        Set<String> statuses = showCompleted == true
            ? new Set<String>{ 'Imported', 'Duplicate' }
            : new Set<String>{ 'Pending', 'Needs Review' };
        return [
            SELECT Id, Name, Job_Title__c, Employer_Name__c, Applied_Date__c, Source_Stage__c, Status__c, Posting_URL__c,
                Recruiting_Contact_Name__c, Recruiting_Email__c, Recruiting_Phone__c,
                Review_Detail__c, Job_Application__c
            FROM Application_Intake__c
            WHERE Status__c IN :statuses
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC, Id DESC
            LIMIT 100
        ];
    }

    @AuraEnabled
    public static String getQueueJson(Boolean showCompleted) {
        try {
            return JSON.serialize(getQueue(showCompleted));
        } catch (QueryException ex) {
            // Use a primitive response for the queue, including when the user-mode query is denied.
            return null;
        }
    }

    @AuraEnabled
    public static String review(Id intakeId, Id employerId) {
        try {
            return reviewIntake(intakeId, employerId);
        } catch (DmlException ex) {
            throw new AuraHandledException(
                'Could not save this intake. Refresh to check for a concurrent import, or ask your admin to verify access and validation rules.'
            );
        } catch (QueryException ex) {
            throw new AuraHandledException('Could not read the intake or its matches. Refresh and verify access.');
        }
    }

    private static String reviewIntake(Id intakeId, Id employerId) {
        List<Application_Intake__c> items = [
            SELECT Id, Source_Record_Key__c, Employer_Name__c, Job_Title__c,
                Applied_Date__c, Source_Stage__c, Status__c, Job_Application__c, Posting_URL__c,
                Recruiting_Contact_Name__c, Recruiting_Email__c, Recruiting_Phone__c
            FROM Application_Intake__c
            WHERE Id = :intakeId
            WITH USER_MODE
            FOR UPDATE
        ];
        if (items.isEmpty()) {
            throw new AuraHandledException('This intake is no longer available.');
        }
        Application_Intake__c item = items[0];
        if (item.Status__c == 'Imported' || item.Status__c == 'Duplicate') {
            return item.Status__c;
        }

        String sourceKey = item.Source_Record_Key__c.toLowerCase();
        Boolean isPosting = !String.isBlank(item.Posting_URL__c);
        Set<String> postingUrls = new Set<String>();
        if (isPosting) {
            CareerHubJobPostingPreview.Result posting = new CareerHubJobPostingPreview.Result();
            postingUrls = CareerHubJobPostingPreview.identify(item.Posting_URL__c, posting);
            if (posting.status == 'UNSUPPORTED' || posting.sourceJobKey != sourceKey) {
                return finish(item.Id, 'Needs Review', 'The posting link does not match this intake. Restage the original link.',
                    null, null);
            }
        }
        List<Job_Application__c> byKey = [
            SELECT Id, Employer__c
            FROM Job_Application__c
            WHERE Source_Job_Key__c = :sourceKey OR Posting_URL__c IN :postingUrls
            WITH USER_MODE
            LIMIT 1
        ];
        if (!byKey.isEmpty()) {
            return finish(item.Id, 'Duplicate', 'This source record already has a job application.',
                byKey[0].Employer__c, byKey[0].Id);
        }

        if (!isPosting && (item.Source_Stage__c != 'Applied' || item.Applied_Date__c == null)) {
            return finish(item.Id, 'Needs Review',
                'Only confirmed Applied records with an application date can be imported. Check the source details.',
                null, null);
        }

        List<Account> accounts;
        if (employerId == null) {
            String employerName = item.Employer_Name__c.trim();
            accounts = [
                SELECT Id FROM Account
                WHERE Name = :employerName
                WITH USER_MODE
                LIMIT 2
                FOR UPDATE
            ];
        } else {
            accounts = [
                SELECT Id FROM Account
                WHERE Id = :employerId
                WITH USER_MODE
                FOR UPDATE
            ];
        }
        if (accounts.size() != 1) {
            String detail = accounts.isEmpty()
                ? 'No accessible employer Account matched. Select the correct Account and review again.'
                : 'More than one employer Account matched. Select the correct Account and review again.';
            return finish(item.Id, 'Needs Review', detail, null, null);
        }

        Id resolvedEmployer = accounts[0].Id;
        String title = item.Job_Title__c.trim();
        if (!isPosting) {
            List<Job_Application__c> byRole = [
                SELECT Id, Stage__c FROM Job_Application__c
                WHERE Employer__c = :resolvedEmployer AND Job_Title__c = :title
                WITH USER_MODE
                LIMIT 2
            ];
            if (byRole.size() > 1) {
                return finish(item.Id, 'Needs Review',
                    'Several job applications match this employer and title. Resolve those matches before importing.',
                    resolvedEmployer, null);
            }
            if (byRole.size() == 1 && (byRole[0].Stage__c == 'Discovered' || byRole[0].Stage__c == 'Interested')) {
                return finish(item.Id, 'Needs Review',
                    'This role already exists as a saved posting. Review and update the existing application before importing.',
                    resolvedEmployer, null);
            }
            if (byRole.size() == 1) {
                return finish(item.Id, 'Duplicate', 'An application with this employer and job title already exists.',
                    resolvedEmployer, byRole[0].Id);
            }

        }

        Job_Application__c application = new Job_Application__c(
            Employer__c = resolvedEmployer,
            Job_Title__c = title,
            Applied_Date__c = isPosting ? null : item.Applied_Date__c,
            Stage__c = isPosting ? 'Discovered' : 'Applied',
            Job_Source__c = sourceKey.startsWith('linkedin:') ? 'LinkedIn' : 'Unknown',
            Posting_URL__c = item.Posting_URL__c,
            Recruiting_Contact_Name__c = item.Recruiting_Contact_Name__c,
            Recruiting_Email__c = item.Recruiting_Email__c,
            Recruiting_Phone__c = item.Recruiting_Phone__c,
            Source_Job_Key__c = sourceKey
        );
        Id recruiterId = findRecruiter(resolvedEmployer, item.Recruiting_Email__c);
        if (recruiterId != null) application.Primary_Recruiter__c = recruiterId;
        insert as user application;
        return finish(item.Id, 'Imported', isPosting ? 'Saved the reviewed job posting as Discovered.' : 'Created a job application from the reviewed confirmation.',
            resolvedEmployer, application.Id);
    }

    private static Id findRecruiter(Id employerId, String email) {
        if (String.isBlank(email) || !Schema.sObjectType.Contact.isAccessible() ||
            !Schema.sObjectType.Contact.fields.AccountId.isAccessible() ||
            !Schema.sObjectType.Contact.fields.Email.isAccessible() ||
            !Schema.sObjectType.Job_Application__c.fields.Primary_Recruiter__c.isCreateable()) return null;
        List<Contact> matches = [
            SELECT Id FROM Contact WHERE AccountId = :employerId AND Email = :email WITH USER_MODE LIMIT 2
        ];
        return matches.size() == 1 ? matches[0].Id : null;
    }

    private static String finish(Id itemId, String status, String detail, Id employerId, Id applicationId) {
        Application_Intake__c outcome = new Application_Intake__c(
            Id = itemId,
            Status__c = status,
            Review_Detail__c = detail,
            Employer__c = employerId,
            Job_Application__c = applicationId
        );
        update as user outcome;
        return status;
    }
}
