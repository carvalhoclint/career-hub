/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 11-08-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
@IsTest
private class CareerHubJobPostingPreviewTest {
    private static final String GREENHOUSE_URL =
        'https://job-boards.greenhouse.io/careerhubdemo/jobs/123456';
    private static final String GREENHOUSE_KEY = 'greenhouse:careerhubdemo:123456';
    private static final String LEVER_URL =
        'https://jobs.lever.co/careerhubdemo/e77f0dec-7249-46d2-8542-e192acc79be4';

    private static final String LINKEDIN_URL = 'https://www.linkedin.com/jobs/view/1234567890';
    private static final String LINKEDIN_VARIANT =
        'https://ca.linkedin.com/jobs/view/revenue-operations-analyst-1234567890/?trackingId=test';

    private class PostingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            String endpoint = request.getEndpoint();
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);

            if (endpoint.startsWith('callout:ScrapingAnt/')) {
                // The HTML has no JobPosting data, so Apex must use the fallback.
                response.setBody('{"status_code":200,"content":"<html></html>"}');
            } else if (endpoint.startsWith(
                'https://boards-api.greenhouse.io/v1/boards/careerhubdemo/jobs/123456'
            )) {
                response.setBody(
                    '{"title":"Revenue Operations Analyst","company_name":"Demo Co",' +
                    '"content":"<p>Build pipeline reports.</p>"}'
                );
            } else if (endpoint.startsWith(
                'https://api.lever.co/v0/postings/careerhubdemo/'
            )) {
                response.setBody(
                    '{"text":"Sales Operations Analyst",' +
                    '"descriptionPlain":"Improve CRM data quality."}'
                );
            } else {
                System.assert(false, 'Unexpected callout: ' + endpoint);
            }

            return response;
        }
    }

    private static CareerHubJobPostingPreview.Result preview(String url) {
        CareerHubJobPostingPreview.Request input =
            new CareerHubJobPostingPreview.Request();
        input.postingUrl = url;

        return CareerHubJobPostingPreview.preview(
            new List<CareerHubJobPostingPreview.Request>{ input }
        )[0];
    }

    @IsTest
    static void greenhouseFallbackPrefillsReview() {
        Test.setMock(HttpCalloutMock.class, new PostingMock());
        Test.startTest();
        CareerHubJobPostingPreview.Result result =
            preview(GREENHOUSE_URL + '?utm_source=test');
        Test.stopTest();

        System.assertEquals('READY', result.status, result.message);
        System.assertEquals(GREENHOUSE_URL, result.canonicalUrl);
        System.assertEquals(GREENHOUSE_KEY, result.sourceJobKey);
        System.assertEquals('Revenue Operations Analyst', result.jobTitle);
        System.assertEquals('Demo Co', result.companyName);
        System.assertEquals('Build pipeline reports.', result.jobDescription);
    }

    @IsTest
    static void leverPrefillsReview() {
        Test.setMock(HttpCalloutMock.class, new PostingMock());
        Test.startTest();
        CareerHubJobPostingPreview.Result result = preview(LEVER_URL);
        Test.stopTest();

        System.assertEquals('READY', result.status, result.message);
        System.assertEquals('Sales Operations Analyst', result.jobTitle);
        System.assertEquals('Improve CRM data quality.', result.jobDescription);
    }

    @IsTest
    static void otherCareerSiteUsesManualEntry() {
        String url = 'https://careers.example.com/jobs/revops';
        Test.startTest();
        CareerHubJobPostingPreview.Result result = preview(url);
        System.assertEquals(0, Limits.getCallouts());
        Test.stopTest();

        System.assertEquals('MANUAL', result.status, result.message);
        System.assertEquals(url, result.canonicalUrl);
        System.assert(String.isNotBlank(result.sourceJobKey));
    }

    @IsTest
    static void linkedInVariantsShareCanonicalUrlAndJobKey() {
        Test.startTest();
        CareerHubJobPostingPreview.Result direct = preview(LINKEDIN_URL);
        CareerHubJobPostingPreview.Result shared = preview(LINKEDIN_VARIANT);
        System.assertEquals(0, Limits.getCallouts(), 'LinkedIn previews must not fetch the posting.');
        Test.stopTest();

        System.assertEquals('MANUAL', direct.status, direct.message);
        System.assertEquals('MANUAL', shared.status, shared.message);
        System.assertEquals(LINKEDIN_URL, direct.canonicalUrl);
        System.assertEquals(LINKEDIN_URL, shared.canonicalUrl);
        System.assertEquals('linkedin:1234567890', direct.sourceJobKey);
        System.assertEquals(direct.sourceJobKey, shared.sourceJobKey);
    }

    @IsTest
    static void linkedInVariantFindsLegacyApplicationByPostingUrl() {
        Account employer = new Account(Name = 'Career Hub LinkedIn Test Employer');
        insert employer;

        Job_Application__c application = new Job_Application__c(
            Employer__c = employer.Id,
            Job_Title__c = 'Revenue Operations Analyst',
            Job_Description__c = 'Build pipeline reports.',
            Stage__c = 'Discovered',
            Job_Source__c = 'LinkedIn',
            Posting_URL__c = LINKEDIN_URL + '/',
            Source_Job_Key__c = 'url:' + EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf(LINKEDIN_URL + '/'))
            )
        );
        insert application;

        Test.startTest();
        CareerHubJobPostingPreview.Result result = preview(LINKEDIN_VARIANT);
        System.assertEquals(0, Limits.getCallouts(), 'Duplicate previews must not make a callout.');
        Test.stopTest();

        System.assertEquals('DUPLICATE', result.status, result.message);
        System.assertEquals(application.Id, result.existingApplicationId);
    }

    @IsTest
    static void duplicateReturnsExistingApplicationBeforeCallout() {
        Account employer = new Account(Name = 'Career Hub Test Employer');
        insert employer;

        Job_Application__c application = new Job_Application__c(
            Employer__c = employer.Id,
            Job_Title__c = 'Revenue Operations Analyst',
            Job_Description__c = 'Build pipeline reports.',
            Stage__c = 'Discovered',
            Job_Source__c = 'Company Careers Site',
            Posting_URL__c = GREENHOUSE_URL,
            Source_Job_Key__c = GREENHOUSE_KEY
        );
        insert application;

        Test.startTest();
        CareerHubJobPostingPreview.Result result =
            preview(GREENHOUSE_URL + '?utm_source=duplicate-test');
        System.assertEquals(0, Limits.getCallouts());
        Test.stopTest();

        System.assertEquals('DUPLICATE', result.status, result.message);
        System.assertEquals(application.Id, result.existingApplicationId);
    }
}
