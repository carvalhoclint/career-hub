public with sharing class CareerHubAgentStageIntake {
    private static final Pattern SOURCE_KEY = Pattern.compile(
        '^(gmail:[0-9a-f]{1,64}|sheet:[0-9a-f]{64})$'
    );
    private static final Pattern ISO_DATE = Pattern.compile('^[0-9]{4}-[0-9]{2}-[0-9]{2}$');

    private static final Set<String> SOURCE_STAGES = new Set<String>{ 'Applied', 'Later Stage', 'Unknown' };

    public class Draft {
        @InvocableVariable(required=true description='An explicitly supplied gmail: or sheet: source key.')
        public String sourceKey;
        @InvocableVariable(required=true description='Employer explicitly identified in the source or confirmed by the user.')
        public String employer;
        @InvocableVariable(required=true description='Job title explicitly identified in the source or confirmed by the user.')
        public String jobTitle;
        @InvocableVariable(required=true description='Applied, Later Stage, or Unknown.')
        public String sourceStage;
        @InvocableVariable(required=true description='Verified date in YYYY-MM-DD format, or Unknown if no reliable date.')
        public String appliedDate;
    }

    public class Result {
        @InvocableVariable public String outcome;
        @InvocableVariable public String intakeId;
        @InvocableVariable public String detail;
    }

    @InvocableMethod(
        label='Stage Career Hub Intake'
        description='Stage confirmed application details in Career Hub without creating a Job Application.'
    )
    public static List<Result> stage(List<Draft> drafts) {
        List<Result> results = new List<Result>();
        List<Application_Intake__c> pending = new List<Application_Intake__c>();
        List<Result> pendingResults = new List<Result>();

        for (Draft draft : drafts) {
            Result result = new Result();
            results.add(result);
            String problem = validate(draft);
            if (problem != null) {
                result.outcome = 'INVALID';
                result.detail = problem;
                continue;
            }
            String stage = draft.sourceStage.trim();
            Date applied = draft.appliedDate.trim().equalsIgnoreCase('Unknown')
                ? null : Date.valueOf(draft.appliedDate.trim());
            pending.add(new Application_Intake__c(
                Source_Record_Key__c = draft.sourceKey.trim().toLowerCase(),
                Employer_Name__c = draft.employer.trim(),
                Job_Title__c = draft.jobTitle.trim(),
                Source_Stage__c = stage,
                Applied_Date__c = applied
            ));
            pendingResults.add(result);
        }

        if (!pending.isEmpty()) {
            List<Database.SaveResult> saved = Database.insert(pending, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < saved.size(); i++) {
                Result result = pendingResults[i];
                if (saved[i].isSuccess()) {
                    result.outcome = 'STAGED';
                    result.intakeId = String.valueOf(saved[i].getId());
                    result.detail = 'Open Application Intake Queue to review the staged record.';
                    continue;
                }
                Boolean duplicate = false;
                for (Database.Error error : saved[i].getErrors()) {
                    if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                        duplicate = true;
                    }
                }
                result.outcome = duplicate ? 'ALREADY_STAGED' : 'NOT_STAGED';
                result.detail = duplicate
                    ? 'This source key is already in the queue. No new intake was created.'
                    : 'The intake could not be staged. Verify reviewer access and the intake validation rules.';
            }
        }
        return results;
    }

    private static String validate(Draft draft) {
        if (draft == null || String.isBlank(draft.sourceKey) ||
            !SOURCE_KEY.matcher(draft.sourceKey.trim().toLowerCase()).matches()) {
            return 'Provide a valid Gmail or spreadsheet source key.';
        }
        if (String.isBlank(draft.employer) || String.isBlank(draft.jobTitle) ||
            draft.employer.trim().length() > 255 || draft.jobTitle.trim().length() > 255) {
            return 'Provide the employer and job title, each at most 255 characters.';
        }
        String stage = String.isBlank(draft.sourceStage) ? '' : draft.sourceStage.trim();
        if (!SOURCE_STAGES.contains(stage)) {
            return 'Use Applied, Later Stage, or Unknown for the source stage.';
        }
        String dateText = String.isBlank(draft.appliedDate) ? '' : draft.appliedDate.trim();
        if (dateText.equalsIgnoreCase('Unknown')) {
            return null;
        }
        if (!ISO_DATE.matcher(dateText).matches()) {
            return 'Provide an application date in YYYY-MM-DD format or Unknown.';
        }
        try {
            Date applied = Date.valueOf(dateText);
            if (applied.year() != Integer.valueOf(dateText.substring(0, 4)) ||
                applied.month() != Integer.valueOf(dateText.substring(5, 7)) ||
                applied.day() != Integer.valueOf(dateText.substring(8, 10))) {
                return 'Provide a valid calendar date or Unknown.';
            }
            if (applied > Date.today()) {
                return 'The application date cannot be in the future.';
            }
        } catch (TypeException ex) {
            return 'Provide a valid calendar date or Unknown.';
        }
        return null;
    }
}
