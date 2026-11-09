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
}
