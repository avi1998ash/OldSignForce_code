/**
 * DocumentEditorControllerGuestTest - coverage for DocumentEditorControllerGuest.convertToPdfViaLambda,
 * the guest-side copy of DocumentEditorController.convertToPdfViaLambda. Same cases as the internal test
 * plus the failure branches (non-200, success=false, callout exception).
 */
@isTest
private class DocumentEditorControllerGuestTest {

    private static ContentVersion makeDocx() {
        ContentVersion cv = new ContentVersion(
            Title = 'test.docx',
            PathOnClient = 'test.docx',
            VersionData = Blob.valueOf('Sample content for testing')
        );
        insert cv;
        return cv;
    }

    @isTest
    static void convert_success_returnsPdfUrl() {
        Test.setMock(HttpCalloutMock.class, new LambdaMock(200, '{"success": true, "url": "https://s3.test.com/preview.pdf"}', false));
        ContentVersion cv = makeDocx();
        Test.startTest();
        String result = DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
        Test.stopTest();
        System.assertEquals('https://s3.test.com/preview.pdf', result);
    }

    @isTest
    static void convert_titleFallbackWhenNoPathOnClient() {
        Test.setMock(HttpCalloutMock.class, new LambdaMock(200, '{"success": true, "url": "https://s3.test.com/p.pdf"}', false));
        // Unsaved record with no PathOnClient: the filename falls back to Title.
        ContentVersion cv = new ContentVersion(Title = 'fallback title', VersionData = Blob.valueOf('x'));
        Test.startTest();
        String result = DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
        Test.stopTest();
        System.assertEquals('https://s3.test.com/p.pdf', result);
    }

    @isTest
    static void convert_non200_throws() {
        Test.setMock(HttpCalloutMock.class, new LambdaMock(500, 'boom', false));
        ContentVersion cv = makeDocx();
        try {
            DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
            System.assert(false, 'expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void convert_successFalse_throws() {
        Test.setMock(HttpCalloutMock.class, new LambdaMock(200, '{"success": false, "error": "bad"}', false));
        ContentVersion cv = makeDocx();
        try {
            DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
            System.assert(false, 'expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void convert_calloutException_throws() {
        Test.setMock(HttpCalloutMock.class, new LambdaMock(200, '', true));
        ContentVersion cv = makeDocx();
        try {
            DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
            System.assert(false, 'expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    private class LambdaMock implements HttpCalloutMock {
        private Integer code;
        private String body;
        private Boolean throwEx;
        LambdaMock(Integer code, String body, Boolean throwEx) {
            this.code = code;
            this.body = body;
            this.throwEx = throwEx;
        }
        public HttpResponse respond(HttpRequest req) {
            if (throwEx) {
                throw new CalloutException('simulated');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body);
            return res;
        }
    }
}
