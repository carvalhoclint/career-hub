@IsTest
private class CareerHubApplicationIntakeTest {
    @TestSetup
    static void createReviewer() {
        PermissionSet reviewerAccess = [
            SELECT Id FROM PermissionSet
            WHERE Name = 'Career_Hub_Intake_Reviewer'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        User reviewer = new User(
            Alias = 'chirev',
            Email = 'career-hub-intake-reviewer@example.com',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LastName = 'CareerHubApplicationIntakeTest',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/Toronto',
            Username = 'career-hub-intake-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128))
                + '@example.com'
        );
        insert as system reviewer;
        insert as system new PermissionSetAssignment(
            AssigneeId = reviewer.Id,
            PermissionSetId = reviewerAccess.Id
        );
    }

    private static User reviewer() {
        return [
            SELECT Id FROM User
            WHERE Alias = 'chirev' AND LastName = 'CareerHubApplicationIntakeTest'
                AND Username LIKE 'career-hub-intake-%@example.com'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    private static Application_Intake__c stage(String messageId, String employerName) {
        Application_Intake__c item = new Application_Intake__c(
            Source_Record_Key__c = 'gmail:' + messageId,
            Source_Stage__c = 'Applied',
            Employer_Name__c = employerName,
            Job_Title__c = 'Revenue Systems Analyst',
            Applied_Date__c = Date.today().addDays(-1)
        );
        insert item;
        return item;
    }

    @IsTest
    static void createsOnceAndBlocksStagingReplay() {
        System.runAs(reviewer()) {
            insert as system new Account(Name = 'Career Hub Queue Clean');
            Application_Intake__c item = stage('a000000000000001', 'Career Hub Queue Clean');
            Test.startTest();
            System.assertEquals('Imported', CareerHubApplicationIntake.review(item.Id, null));
            System.assertEquals('Imported', CareerHubApplicationIntake.review(item.Id, null));
            Test.stopTest();

            Job_Application__c application = [
                SELECT Id, Stage__c, Applied_Date__c FROM Job_Application__c
                WHERE Source_Job_Key__c = 'gmail:a000000000000001'
            ];
            System.assertEquals('Applied', application.Stage__c);
            System.assertEquals(Date.today().addDays(-1), application.Applied_Date__c);
            Application_Intake__c saved = [
                SELECT Job_Application__c FROM Application_Intake__c WHERE Id = :item.Id
            ];
            System.assertEquals(application.Id, saved.Job_Application__c);

            item.Id = null;
            item.Source_Record_Key__c = 'gmail:a000000000000001';
            Database.SaveResult replay = Database.insert(item, false);
            System.assertEquals(false, replay.isSuccess());
            System.assertEquals(StatusCode.DUPLICATE_VALUE, replay.getErrors()[0].getStatusCode());
        }
    }

    @IsTest
    static void linksHistoricGmailImportAndDifferentMessageForSameRole() {
        System.runAs(reviewer()) {
            Account employer = new Account(Name = 'Career Hub Queue Existing');
            insert as system employer;
            Job_Application__c existing = new Job_Application__c(
                Job_Title__c = 'Revenue Systems Analyst',
                Employer__c = employer.Id,
                Stage__c = 'Applied',
                Applied_Date__c = Date.today().addDays(-2),
                Source_Job_Key__c = 'gmail:a000000000000002'
            );
            insert existing;
            Application_Intake__c sameMessage = stage('a000000000000002', 'Unmatched Name');
            Application_Intake__c sameRole = stage('a000000000000003', employer.Name);
            Test.startTest();
            System.assertEquals('Duplicate', CareerHubApplicationIntake.review(sameMessage.Id, null));
            System.assertEquals('Duplicate', CareerHubApplicationIntake.review(sameRole.Id, null));
            Test.stopTest();

            List<Application_Intake__c> linked = [
                SELECT Job_Application__c FROM Application_Intake__c WHERE Job_Application__c = :existing.Id
            ];
            System.assertEquals(2, linked.size());
            System.assertEquals(1, [SELECT COUNT() FROM Job_Application__c WHERE Employer__c = :employer.Id]);
        }
    }

    @IsTest
    static void holdsAmbiguousEmployerUntilExplicitSelection() {
        System.runAs(reviewer()) {
            Account first = new Account(Name = 'Career Hub Ambiguous Employer');
            Account second = new Account(Name = first.Name);
            Database.DMLOptions options = new Database.DMLOptions();
            options.DuplicateRuleHeader.allowSave = true;
            first.setOptions(options);
            second.setOptions(options);
            insert as system first;
            insert as system second;
            Application_Intake__c item = stage('a000000000000004', first.Name);
            Test.startTest();
            System.assertEquals('Needs Review', CareerHubApplicationIntake.review(item.Id, null));
            System.assertEquals(0, [SELECT COUNT() FROM Job_Application__c WHERE Source_Job_Key__c = 'gmail:a000000000000004']);
            System.assertEquals('Imported', CareerHubApplicationIntake.review(item.Id, second.Id));
            Test.stopTest();

            Job_Application__c application = [
                SELECT Employer__c FROM Job_Application__c WHERE Source_Job_Key__c = 'gmail:a000000000000004'
            ];
            System.assertEquals(second.Id, application.Employer__c);
        }
    }

    @IsTest
    static void filtersOpenAndCompletedAndHoldsMissingEmployer() {
        System.runAs(reviewer()) {
            Account employer = new Account(Name = 'Career Hub Queue Available');
            insert as system employer;
            Application_Intake__c missing = stage('a000000000000005', 'Career Hub Queue Not Found');
            Application_Intake__c available = stage('a000000000000006', employer.Name);
            Test.startTest();
            System.assertEquals(2, CareerHubApplicationIntake.getQueue(false).size());
            System.assertEquals('Needs Review', CareerHubApplicationIntake.review(missing.Id, null));
            System.assertEquals('Imported', CareerHubApplicationIntake.review(available.Id, null));
            List<Application_Intake__c> openItems = CareerHubApplicationIntake.getQueue(false);
            List<Application_Intake__c> completed = CareerHubApplicationIntake.getQueue(true);
            Test.stopTest();

            System.assertEquals(1, openItems.size());
            System.assertEquals(missing.Id, openItems[0].Id);
            System.assertEquals(1, completed.size());
            System.assertEquals(available.Id, completed[0].Id);
        }
    }

    @IsTest
    static void holdsSpreadsheetRowsWithMissingDatesOrHistoricalStages() {
        System.runAs(reviewer()) {
            insert as system new Account(Name = 'Career Hub Sheet Employer');
            String firstKey = 'sheet:' + EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf('synthetic missing date'))
            );
            String secondKey = 'sheet:' + EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf('synthetic later stage'))
            );
            Application_Intake__c missingDate = new Application_Intake__c(
                Source_Record_Key__c = firstKey,
                Source_Stage__c = 'Applied',
                Employer_Name__c = 'Career Hub Sheet Employer',
                Job_Title__c = 'Revenue Systems Analyst'
            );
            Application_Intake__c laterStage = new Application_Intake__c(
                Source_Record_Key__c = secondKey,
                Source_Stage__c = 'Later Stage',
                Employer_Name__c = 'Career Hub Sheet Employer',
                Job_Title__c = 'Business Systems Analyst',
                Applied_Date__c = Date.today().addDays(-2)
            );
            insert new List<Application_Intake__c>{ missingDate, laterStage };
            Test.startTest();
            System.assertEquals('Needs Review', CareerHubApplicationIntake.review(missingDate.Id, null));
            System.assertEquals('Needs Review', CareerHubApplicationIntake.review(laterStage.Id, null));
            Test.stopTest();

            Set<String> keys = new Set<String>{ firstKey, secondKey };
            System.assertEquals(0, [SELECT COUNT() FROM Job_Application__c WHERE Source_Job_Key__c IN :keys]);

            missingDate.Applied_Date__c = Date.today().addDays(-3);
            update missingDate;
            System.assertEquals('Imported', CareerHubApplicationIntake.review(missingDate.Id, null));
            System.assertEquals(1, [SELECT COUNT() FROM Job_Application__c WHERE Source_Job_Key__c IN :keys]);
        }
    }

}
