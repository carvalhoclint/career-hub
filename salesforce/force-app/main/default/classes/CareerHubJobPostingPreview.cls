/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 11-08-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
public with sharing class CareerHubJobPostingPreview {
    public class Request {
        @InvocableVariable(required=true)
        public String postingUrl;
    }

    public class Result {
        @InvocableVariable public String status;
        @InvocableVariable public String message;
        @InvocableVariable public String sourceJobKey;
        @InvocableVariable public String canonicalUrl;
        @InvocableVariable public Id existingApplicationId;
        @InvocableVariable public String jobTitle;
        @InvocableVariable public String companyName;
        @InvocableVariable public String jobDescription;
    }

    @InvocableMethod(label='Preview Job Posting' callout=true)
    public static List<Result> preview(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request input : requests) {
            Result result = new Result();
            results.add(result);
            if (requests.size() != 1) {
                result.status = 'UNSUPPORTED';
                result.message = 'Enter one job posting at a time.';
                continue;
            }
            previewOne(input, result);
        }
        return results;
    }

    private static void previewOne(Request input, Result result) {
        String original = input.postingUrl == null ? '' : input.postingUrl.trim();
        Matcher link = Pattern.compile(
            '(?i)^https://(?:job-boards|boards)\\.greenhouse\\.io/' +
            '([a-z0-9_-]+)/jobs/([0-9]+)/?(?:[?#][^\\s]*)?$'
        ).matcher(original);

       Boolean isGreenhouse = link.matches();
String board;
Set<String> urls = new Set<String>{ original };

if (isGreenhouse) {
    board = link.group(1).toLowerCase();
    String path = '/' + board + '/jobs/' + link.group(2);
    result.sourceJobKey = 'greenhouse:' + board + ':' + link.group(2);
    result.canonicalUrl = 'https://job-boards.greenhouse.io' + path;
    urls.add('https://boards.greenhouse.io' + path);
} else {
    Matcher webLink = Pattern.compile(
        '(?i)^https://([a-z0-9.-]+\\.[a-z]{2,})(?::443)?([/?][^\\s#]*)?(?:#[^\\s]*)?$'
    ).matcher(original);

    if (!webLink.matches()) {
        result.status = 'UNSUPPORTED';
        result.message = 'Enter a complete HTTPS job posting link.';
        return;
    }

    String pathAndQuery = webLink.group(2);
    result.canonicalUrl = 'https://' + webLink.group(1).toLowerCase() +
        (pathAndQuery == null ? '' : pathAndQuery);
    result.sourceJobKey = 'url:' + EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(result.canonicalUrl))
    );
}

Matcher leverLink = Pattern.compile(
    '(?i)^https://jobs\\.lever\\.co/([a-z0-9_-]+)/' +
    '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})' +
    '(?:/apply)?/?(?:\\?.*)?$'
).matcher(result.canonicalUrl);

Boolean isLever = !isGreenhouse && leverLink.matches();

if (isLever) {
    result.canonicalUrl = 'https://jobs.lever.co/' +
        leverLink.group(1).toLowerCase() + '/' +
        leverLink.group(2).toLowerCase();
    result.sourceJobKey = 'url:' + EncodingUtil.convertToHex(
        Crypto.generateDigest('SHA-256', Blob.valueOf(result.canonicalUrl))
    );
}
urls.add(result.canonicalUrl);
        List<Job_Application__c> matches = [
            SELECT Id FROM Job_Application__c
            WHERE Source_Job_Key__c = :result.sourceJobKey
               OR Posting_URL__c IN :urls
            WITH USER_MODE
            LIMIT 1
        ];
        if (!matches.isEmpty()) {
            result.status = 'DUPLICATE';
            result.message = 'This posting is already in Career Hub.';
            result.existingApplicationId = matches[0].Id;
            return;
        }
        if (isLever) {
    try {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.lever.co/v0/postings/' +
            leverLink.group(1).toLowerCase() + '/' +
            leverLink.group(2).toLowerCase());
        req.setMethod('GET');
        req.setTimeout(10000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() == 200) {
            Map<String, Object> job =
                (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            result.jobTitle = plainText(job.get('text'));
            result.jobDescription = (String) job.get('descriptionPlain');

            if (!String.isBlank(result.jobTitle)) {
                result.status = 'READY';
                result.message = 'Review the extracted details before saving.';
                return;
            }
        }
    } catch (Exception ex) {
        // Fall through to manual entry.
    }
}
        if (!isGreenhouse) {
            result.status = 'MANUAL';
            result.message = 'Enter the job details below. We will keep the posting link.';
            return;
        }
        try {
            HttpRequest request = new HttpRequest();
            request.setEndpoint('callout:ScrapingAnt/v1/general?url=' +
                EncodingUtil.urlEncode(result.canonicalUrl, 'UTF-8') +
                '&browser=false');
            request.setMethod('GET');
            request.setTimeout(30000);
            HttpResponse response = new Http().send(request);

            if (response.getStatusCode() == 200) {
                Map<String, Object> body =
                    (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
                if (String.valueOf(body.get('status_code')) == '200' &&
                    body.get('content') instanceof String) {
                    readPosting((String) body.get('content'), result);
                    if (String.isBlank(result.jobTitle)) {
    readGreenhouseJob(board, link.group(2), result);
}
                    result.status = String.isBlank(result.jobTitle) ? 'MANUAL' : 'READY';
                    result.message = result.status == 'READY'
                        ? 'Review the extracted details before saving.'
                        : 'The page was fetched. Enter the job details manually.';
                    return;
                }
            }
        } catch (Exception ex) {
            // Use the same fallback without exposing the response or credentials.
        }
        result.status = 'MANUAL';
        result.message = 'The posting could not be fetched. Enter the details manually.';
    }

    private static void readPosting(String html, Result result) {
        Matcher blocks = Pattern.compile(
            '(?is)<script\\b[^>]*application/ld\\+json[^>]*>(.*?)</script\\s*>'
        ).matcher(html);
        while (blocks.find()) {
            try {
                Object parsed = JSON.deserializeUntyped(blocks.group(1).trim());
                if (!(parsed instanceof Map<String, Object>)) continue;
                Map<String, Object> job = (Map<String, Object>) parsed;
                if ('JobPosting' != job.get('@type')) continue;
                result.jobTitle = plainText(job.get('title'));
                result.jobDescription = plainText(job.get('description'));
                if (job.get('hiringOrganization') instanceof Map<String, Object>) {
                    Map<String, Object> employer =
                        (Map<String, Object>) job.get('hiringOrganization');
                    result.companyName = plainText(employer.get('name'));
                }
                return;
            } catch (JSONException ex) {
                // Try the next structured data block.
            }
        }
    }
private static void readGreenhouseJob(String board, String jobId, Result result) {
    try {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://boards-api.greenhouse.io/v1/boards/' +
            board + '/jobs/' + jobId);
        req.setMethod('GET');
        req.setTimeout(10000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) return;

        Map<String, Object> job =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        result.jobTitle = plainText(job.get('title'));
        result.companyName = plainText(job.get('company_name'));
        result.jobDescription = plainText(job.get('content'));
    } catch (Exception ex) {
        // Keep manual entry available if the API lookup fails.
    }
}
    private static String plainText(Object value) {
        if (!(value instanceof String)) return null;
        return ((String) value).unescapeHtml4().stripHtmlTags().trim();
    }
}