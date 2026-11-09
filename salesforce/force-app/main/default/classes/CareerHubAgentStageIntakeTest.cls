@IsTest
private class CareerHubAgentStageIntakeTest {
    @TestSetup
    static void setUpReviewer() {
        PermissionSet access = [
            SELECT Id FROM PermissionSet WHERE Name = 'Career_Hub_Intake_Reviewer'
            WITH SYSTEM_MODE LIMIT 1
        ];
        User reviewer = new User(
            Alias = 'chagent',
            Email = 'career-hub-agent-test@example.com',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LastName = 'CareerHubAgentStageIntakeTest',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/Toronto',
            Username = 'career-hub-agent-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128))
                + '@example.com'
        );
        insert as system reviewer;
        insert as system new PermissionSetAssignment(
            AssigneeId = reviewer.Id,
            PermissionSetId = access.Id
        );
    }

    private static User reviewer() {
        return [
            SELECT Id FROM User
            WHERE Alias = 'chagent' AND LastName = 'CareerHubAgentStageIntakeTest'
                AND Username LIKE 'career-hub-agent-%@example.com'
            WITH SYSTEM_MODE LIMIT 1
        ];
    }

    private static CareerHubAgentStageIntake.Draft draft(String key, String stage, String dateText) {
        CareerHubAgentStageIntake.Draft input = new CareerHubAgentStageIntake.Draft();
        input.sourceKey = key;
        input.postingUrl = 'None';
        input.employer = 'Synthetic Employer';
        input.jobTitle = 'Business Systems Analyst';
        input.sourceStage = stage;
        input.appliedDate = dateText;
        return input;
    }

    @IsTest
    static void stagesDraftAndBlocksReplay() {
        System.runAs(reviewer()) {
            CareerHubAgentStageIntake.Draft input = draft('GMAIL:c300000000000001', 'Applied', '2026-09-01');
            List<CareerHubAgentStageIntake.Draft> request = new List<CareerHubAgentStageIntake.Draft>{ input };
            System.assertEquals('STAGED', CareerHubAgentStageIntake.stage(request)[0].outcome);
            System.assertEquals('ALREADY_STAGED', CareerHubAgentStageIntake.stage(request)[0].outcome);
            Application_Intake__c item = [
                SELECT Employer_Name__c, Job_Title__c, Source_Stage__c, Applied_Date__c, Status__c
                FROM Application_Intake__c WHERE Source_Record_Key__c = 'gmail:c300000000000001'
            ];
            System.assertEquals('Synthetic Employer', item.Employer_Name__c);
            System.assertEquals('Business Systems Analyst', item.Job_Title__c);
            System.assertEquals('Applied', item.Source_Stage__c);
            System.assertEquals(Date.newInstance(2026, 9, 1), item.Applied_Date__c);
            System.assertEquals('Pending', item.Status__c);
            System.assertEquals(0, [
                SELECT COUNT() FROM Job_Application__c WHERE Source_Job_Key__c = 'gmail:c300000000000001'
            ]);
        }
    }

    @IsTest
    static void preservesUnknownDateAndHistoricalStage() {
        System.runAs(reviewer()) {
            String key = 'sheet:' + EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf('synthetic spreadsheet row'))
            );
            List<CareerHubAgentStageIntake.Result> results = CareerHubAgentStageIntake.stage(
                new List<CareerHubAgentStageIntake.Draft>{ draft(key, 'Later Stage', 'Unknown') }
            );
            System.assertEquals('STAGED', results[0].outcome);
            Application_Intake__c item = [
                SELECT Source_Stage__c, Applied_Date__c, Status__c
                FROM Application_Intake__c WHERE Source_Record_Key__c = :key
            ];
            System.assertEquals('Later Stage', item.Source_Stage__c);
            System.assertEquals(null, item.Applied_Date__c);
            System.assertEquals('Pending', item.Status__c);
        }
    }

    @IsTest
    static void invalidDraftsDoNotPreventAValidDraftFromStaging() {
        System.runAs(reviewer()) {
            CareerHubAgentStageIntake.Draft missingTitle = draft('gmail:c300000000000002', 'Applied', 'Unknown');
            missingTitle.jobTitle = ' ';
            List<CareerHubAgentStageIntake.Result> results = CareerHubAgentStageIntake.stage(
                new List<CareerHubAgentStageIntake.Draft>{
                    draft('not-a-source-key', 'Applied', 'Unknown'),
                    draft('gmail:c300000000000003', 'Applied', 'Mar 3'),
                    draft('gmail:c300000000000004', 'Applied', '2999-01-01'),
                    draft('gmail:c300000000000005', 'Rejected', 'Unknown'),
                    draft('gmail:c300000000000007', 'Applied', '2024-02-30'),
                    missingTitle,
                    draft('gmail:c300000000000006', 'Unknown', 'Unknown')
                }
            );
            System.assertEquals(7, results.size());
            for (Integer i = 0; i < 6; i++) {
                System.assertEquals('INVALID', results[i].outcome);
            }
            System.assertEquals('STAGED', results[6].outcome);
            System.assertEquals(1, [SELECT COUNT() FROM Application_Intake__c]);
        }
    }

    @IsTest
    static void plainEmailStagesRecruitingDetailsAndBlocksReplay() {
        System.runAs(reviewer()) {
            CareerHubAgentStageIntake.Draft input = draft('Auto', 'Applied', '2026-09-01');
            input.contactName = 'Alex Example';
            input.contactEmail = 'alex@example.com';
            input.contactPhone = '+1 (416) 555-0100';
            List<CareerHubAgentStageIntake.Draft> request = new List<CareerHubAgentStageIntake.Draft>{ input };
            System.assertEquals('STAGED', CareerHubAgentStageIntake.stage(request)[0].outcome);
            input.employer = '  SYNTHETIC   EMPLOYER ';
            System.assertEquals('ALREADY_STAGED', CareerHubAgentStageIntake.stage(request)[0].outcome);
            Application_Intake__c item = [
                SELECT Source_Record_Key__c, Recruiting_Contact_Name__c, Recruiting_Email__c, Recruiting_Phone__c
                FROM Application_Intake__c
            ];
            System.assert(item.Source_Record_Key__c.startsWith('email:'));
            System.assertEquals('Alex Example', item.Recruiting_Contact_Name__c);
            System.assertEquals('alex@example.com', item.Recruiting_Email__c);
            System.assertEquals('+1 (416) 555-0100', item.Recruiting_Phone__c);
        }
    }

    @IsTest
    static void linkPreviewAndReviewPreserveCanonicalUrlAndNeverMarkApplied() {
        System.runAs(reviewer()) {
            Account employer = new Account(Name = 'Synthetic Employer');
            insert employer;
            Contact recruiter = new Contact(LastName = 'Example', AccountId = employer.Id, Email = 'alex@example.com');
            insert recruiter;
            CareerHubAgentPreviewPosting.Request preview = new CareerHubAgentPreviewPosting.Request();
            preview.postingUrl = 'https://ca.linkedin.com/jobs/view/business-analyst-1234567?tracking=test';
            List<CareerHubAgentPreviewPosting.Request> links = new List<CareerHubAgentPreviewPosting.Request>{ preview };
            CareerHubAgentPreviewPosting.Result beforeSave = CareerHubAgentPreviewPosting.preview(links)[0];
            System.assertEquals('MANUAL', beforeSave.status);
            System.assertEquals('https://www.linkedin.com/jobs/view/1234567', beforeSave.canonicalUrl);

            CareerHubAgentStageIntake.Draft input = draft('Auto', 'Applied', '2026-09-01');
            input.postingUrl = preview.postingUrl;
            input.contactEmail = recruiter.Email;
            List<CareerHubAgentStageIntake.Draft> request = new List<CareerHubAgentStageIntake.Draft>{ input };
            System.assertEquals('INVALID', CareerHubAgentStageIntake.stage(request)[0].outcome);
            input.sourceStage = 'Unknown';
            input.appliedDate = 'Unknown';
            CareerHubAgentStageIntake.Result staged = CareerHubAgentStageIntake.stage(request)[0];
            System.assertEquals('STAGED', staged.outcome, staged.detail);
            input.postingUrl = beforeSave.canonicalUrl;
            System.assertEquals('ALREADY_STAGED', CareerHubAgentStageIntake.stage(request)[0].outcome);
            System.assertEquals(0, [SELECT COUNT() FROM Job_Application__c]);
            System.assertEquals('Imported', CareerHubApplicationIntake.review((Id) staged.intakeId, null));

            Job_Application__c job = [
                SELECT Id, Employer__c, Stage__c, Applied_Date__c, Posting_URL__c, Recruiting_Email__c,
                    Primary_Recruiter__c, Job_Source__c
                FROM Job_Application__c WHERE Source_Job_Key__c = 'linkedin:1234567'
            ];
            System.assertEquals('Discovered', job.Stage__c);
            System.assertEquals(null, job.Applied_Date__c);
            System.assertEquals(employer.Id, job.Employer__c);
            System.assertEquals('LinkedIn', job.Job_Source__c);
            System.assertEquals(beforeSave.canonicalUrl, job.Posting_URL__c);
            System.assertEquals(recruiter.Email, job.Recruiting_Email__c);
            System.assertEquals(recruiter.Id, job.Primary_Recruiter__c);
            CareerHubAgentPreviewPosting.Result existing = CareerHubAgentPreviewPosting.preview(links)[0];
            System.assertEquals('DUPLICATE', existing.status);
            System.assertEquals(String.valueOf(job.Id), existing.existingApplicationId);
        }
    }

    @IsTest
    static void stagesAgentforceMarkdownLinkWithSameKeyAsPlainUrl() {
        System.runAs(reviewer()) {
            String url = 'https://job-boards.greenhouse.io/unitriteam/jobs/4485031009';
            CareerHubAgentStageIntake.Draft input = draft('Auto', 'Unknown', 'Unknown');
            input.postingUrl = '[' + url + '](' + url + '1)';
            List<CareerHubAgentStageIntake.Draft> request = new List<CareerHubAgentStageIntake.Draft>{ input };
            System.assertEquals('INVALID', CareerHubAgentStageIntake.stage(request)[0].outcome);

            input.postingUrl = '[' + url + '](' + url + ')';
            CareerHubAgentStageIntake.Result staged = CareerHubAgentStageIntake.stage(request)[0];
            System.assertEquals('STAGED', staged.outcome, staged.detail);
            Id intakeId = (Id) staged.intakeId;
            Application_Intake__c item = [
                SELECT Posting_URL__c, Source_Record_Key__c FROM Application_Intake__c
                WHERE Id = :intakeId
            ];
            System.assertEquals(url, item.Posting_URL__c);
            System.assertEquals('greenhouse:unitriteam:4485031009', item.Source_Record_Key__c);

            input.postingUrl = url;
            System.assertEquals('ALREADY_STAGED', CareerHubAgentStageIntake.stage(request)[0].outcome);
        }
    }
}
