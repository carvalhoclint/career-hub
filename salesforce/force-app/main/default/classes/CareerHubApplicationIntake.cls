public with sharing class CareerHubApplicationIntake {
    @AuraEnabled(cacheable=true)
    public static List<Application_Intake__c> getQueue(Boolean showCompleted) {
        Set<String> statuses = showCompleted == true
            ? new Set<String>{ 'Imported', 'Duplicate' }
            : new Set<String>{ 'Pending', 'Needs Review' };
        return [
            SELECT Id, Name, Job_Title__c, Employer_Name__c, Applied_Date__c, Source_Stage__c, Status__c,
                Review_Detail__c, Job_Application__c
            FROM Application_Intake__c
            WHERE Status__c IN :statuses
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC, Id DESC
            LIMIT 100
        ];
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
                Applied_Date__c, Source_Stage__c, Status__c, Job_Application__c
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
        List<Job_Application__c> byKey = [
            SELECT Id, Employer__c
            FROM Job_Application__c
            WHERE Source_Job_Key__c = :sourceKey
            WITH USER_MODE
            LIMIT 1
        ];
        if (!byKey.isEmpty()) {
            return finish(item.Id, 'Duplicate', 'This source record already has a job application.',
                byKey[0].Employer__c, byKey[0].Id);
        }

        if (item.Source_Stage__c != 'Applied' || item.Applied_Date__c == null) {
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
        List<Job_Application__c> byRole = [
            SELECT Id FROM Job_Application__c
            WHERE Employer__c = :resolvedEmployer AND Job_Title__c = :title
            WITH USER_MODE
            LIMIT 2
        ];
        if (byRole.size() > 1) {
            return finish(item.Id, 'Needs Review',
                'Several job applications match this employer and title. Resolve those matches before importing.',
                resolvedEmployer, null);
        }
        if (byRole.size() == 1) {
            return finish(item.Id, 'Duplicate', 'An application with this employer and job title already exists.',
                resolvedEmployer, byRole[0].Id);
        }

        Job_Application__c application = new Job_Application__c(
            Employer__c = resolvedEmployer,
            Job_Title__c = title,
            Applied_Date__c = item.Applied_Date__c,
            Stage__c = 'Applied',
            Job_Source__c = 'Unknown',
            Source_Job_Key__c = sourceKey
        );
        insert as user application;
        return finish(item.Id, 'Imported', 'Created a job application from the reviewed confirmation.',
            resolvedEmployer, application.Id);
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
