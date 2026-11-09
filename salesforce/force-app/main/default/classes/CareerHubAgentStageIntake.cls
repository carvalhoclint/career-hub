public with sharing class CareerHubAgentStageIntake {
    private static final Pattern SOURCE_KEY = Pattern.compile(
        '^(gmail:[0-9a-f]{1,64}|sheet:[0-9a-f]{64})$'
    );
    private static final Pattern ISO_DATE = Pattern.compile('^[0-9]{4}-[0-9]{2}-[0-9]{2}$');

    private static final Set<String> SOURCE_STAGES = new Set<String>{ 'Applied', 'Later Stage', 'Unknown' };

    public class Draft {
        @InvocableVariable(required=true description='Explicit Gmail or sheet source key, or Auto to generate a key.')
        public String sourceKey;
        @InvocableVariable(required=true description='Confirmed HTTPS job posting URL, or None for an email.')
        public String postingUrl;
        @InvocableVariable(required=true description='Explicit recruiting contact name, or None.')
        public String contactName;
        @InvocableVariable(required=true description='Explicit recruiting email address, or None.')
        public String contactEmail;
        @InvocableVariable(required=true description='Explicit recruiting phone number, or None.')
        public String contactPhone;
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
            Boolean isPosting = !draft.postingUrl.trim().equalsIgnoreCase('None');
            String key;
            String canonicalUrl;
            if (isPosting) {
                CareerHubJobPostingPreview.Result posting = new CareerHubJobPostingPreview.Result();
                CareerHubJobPostingPreview.identify(draft.postingUrl, posting);
                if (posting.status == 'UNSUPPORTED' || String.isBlank(posting.canonicalUrl) ||
                    String.isBlank(posting.sourceJobKey)) {
                    String suppliedUrl = draft.postingUrl.trim();
                    String shape = suppliedUrl.toLowerCase().startsWith('https://') ? 'HTTPS'
                        : (suppliedUrl.startsWith('[') ? 'wrapped link' : 'other');
                    result.outcome = 'INVALID';
                    result.detail = 'The posting link could not be parsed (input type: ' + shape +
                        ', length: ' + suppliedUrl.length() + '). Provide a complete HTTPS job posting link.';
                    continue;
                }
                if (posting.canonicalUrl.length() > 255) {
                    result.outcome = 'INVALID';
                    result.detail = 'The normalized posting link exceeds the 255-character limit.';
                    continue;
                }
                if (posting.sourceJobKey.length() > 80) {
                    result.outcome = 'INVALID';
                    result.detail = 'The posting source key exceeds the 80-character limit.';
                    continue;
                }
                key = posting.sourceJobKey;
                canonicalUrl = posting.canonicalUrl;
            } else if (draft.sourceKey.trim().equalsIgnoreCase('Auto')) {
                String identity = JSON.serialize(new List<String>{
                    draft.employer.trim().replaceAll('\\s+', ' ').toLowerCase(),
                    draft.jobTitle.trim().replaceAll('\\s+', ' ').toLowerCase(),
                    draft.appliedDate.trim().toLowerCase()
                });
                key = 'email:' + EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(identity)));
            } else {
                key = draft.sourceKey.trim().toLowerCase();
            }
            String stage = draft.sourceStage.trim();
            Date applied = draft.appliedDate.trim().equalsIgnoreCase('Unknown')
                ? null : Date.valueOf(draft.appliedDate.trim());
            pending.add(new Application_Intake__c(
                Source_Record_Key__c = key,
                Posting_URL__c = canonicalUrl,
                Recruiting_Contact_Name__c = provided(draft.contactName),
                Recruiting_Email__c = provided(draft.contactEmail),
                Recruiting_Phone__c = provided(draft.contactPhone),
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

    private static String provided(String value) {
        return String.isBlank(value) || value.trim().equalsIgnoreCase('None') ? null : value.trim();
    }

    private static String validate(Draft draft) {
        if (draft == null || String.isBlank(draft.postingUrl) || String.isBlank(draft.sourceKey) ||
            (!draft.sourceKey.trim().equalsIgnoreCase('Auto') &&
             !SOURCE_KEY.matcher(draft.sourceKey.trim().toLowerCase()).matches())) {
            return 'Use Auto or a valid original email source key, and supply the posting link or None.';
        }
        if (!draft.postingUrl.trim().equalsIgnoreCase('None') &&
            (!draft.sourceKey.trim().equalsIgnoreCase('Auto') ||
             draft.sourceStage != 'Unknown' || draft.appliedDate != 'Unknown')) {
            return 'A posting alone cannot verify an application. Use Auto and leave the stage and application date unknown.';
        }
        if (String.isBlank(draft.employer) || String.isBlank(draft.jobTitle) ||
            draft.employer.trim().length() > 255 || draft.jobTitle.trim().length() > 255) {
            return 'Provide the employer and job title, each at most 255 characters.';
        }
        String email = provided(draft.contactEmail);
        String phone = provided(draft.contactPhone);
        String name = provided(draft.contactName);
        if ((name != null && name.length() > 120) ||
            (email != null && (email.length() > 80 ||
             !Pattern.matches('^[^@\\s<>]+@[^@\\s<>]+[.][^@\\s<>]+$', email))) ||
            (phone != null && (phone.length() > 40 ||
             !Pattern.matches('^[+0-9(). /#xX-]*[0-9][+0-9(). /#xX-]*$', phone)))) {
            return 'Provide a valid recruiting contact name, email address, and phone number, or leave them blank.';
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
