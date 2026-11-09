public with sharing class CareerHubAgentPreviewPosting {
    public class Request {
        @InvocableVariable(required=true) public String postingUrl;
    }

    public class Result {
        @InvocableVariable public String status;
        @InvocableVariable public String canonicalUrl;
        @InvocableVariable public String jobTitle;
        @InvocableVariable public String companyName;
        @InvocableVariable public String postingExcerpt;
        @InvocableVariable public String existingApplicationId;
    }

    @InvocableMethod(label='Preview Career Hub Intake Link' callout=true)
    public static List<Result> preview(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request input : requests) {
            Result output = new Result();
            results.add(output);
            if (requests.size() != 1 || input == null) {
                output.status = 'UNSUPPORTED';
                continue;
            }
            CareerHubJobPostingPreview.Request request = new CareerHubJobPostingPreview.Request();
            request.postingUrl = input.postingUrl;
            try {
                CareerHubJobPostingPreview.Result posting = CareerHubJobPostingPreview.preview(
                    new List<CareerHubJobPostingPreview.Request>{ request }
                )[0];
                output.status = posting.status;
                output.canonicalUrl = posting.canonicalUrl;
                output.jobTitle = posting.jobTitle;
                output.companyName = posting.companyName;
                output.existingApplicationId = posting.existingApplicationId == null
                    ? null : String.valueOf(posting.existingApplicationId);
                output.postingExcerpt = posting.jobDescription == null ? null : posting.jobDescription.left(8000);
            } catch (QueryException ex) {
                output.status = 'UNAVAILABLE';
            }
        }
        return results;
    }
}
