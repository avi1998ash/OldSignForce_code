/**
 * DocumentEditorControllerGuest - guest-side copy of DocumentEditorController.convertToPdfViaLambda.
 *
 * The guest signing flows (GuestSigningApi, AgreementControllerGuest) need DOCX/DOC files
 * converted to PDF through the Lambda before PDF.js can render them. They call this class;
 * the internal editor (DocumentEditorController.getPublicPreviewUrl) keeps its own copy.
 *
 * SHARING: `with sharing`, identical to DocumentEditorController. The method does no SOQL or
 * DML - it only reads the Lambda endpoint from SignForce_Config__mdt and makes the callout - so
 * sharing has no effect on its behaviour for either audience.
 *
 * The method body is a verbatim copy: same signature, same AuraHandledException messages.
 */
public with sharing class DocumentEditorControllerGuest {

    /**
     * Calls Lambda's convertToPdf action with a ContentVersion's bytes.
     * Returns the S3 presigned PDF URL on success, throws on failure.
     */
    public static String convertToPdfViaLambda(ContentVersion cv) {
        String endpoint;
        try {
            endpoint = SignForceConfigServiceGuest.getLambdaEndpoint();
        } catch (Exception e) {
            throw new AuraHandledException(
                'Lambda endpoint is not configured. Ask your admin to set '
                + 'Lambda_Endpoint__c on SignForce_Config__mdt.'
            );
        }
        if (String.isBlank(endpoint)) {
            throw new AuraHandledException('Lambda endpoint is not configured');
        }

        Map<String, Object> config = SignForceConfigServiceGuest.getClientConfig();
        String orgId = (String) config.get('orgId');
        String docId = 'agrpreview_' + cv.Id + '_' + String.valueOf(System.currentTimeMillis());
        String fileName = String.isNotBlank(cv.PathOnClient)
            ? cv.PathOnClient
            : (String.isNotBlank(cv.Title) ? cv.Title : 'document.docx');

        Map<String, Object> payload = new Map<String, Object>{
            'action'   => 'convertToPdf',
            'orgId'    => orgId,
            'docId'    => docId,
            'base64'   => EncodingUtil.base64Encode(cv.VersionData),
            'filename' => fileName
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);   // LibreOffice cold start can take ~5-10s
        req.setBody(JSON.serialize(payload));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            throw new AuraHandledException('Lambda call failed: ' + e.getMessage());
        }
        if (res.getStatusCode() != 200) {
            String body = res.getBody() == null ? '' : res.getBody();
            String snippet = body.substring(0, Math.min(500, body.length()));
            throw new AuraHandledException(
                'Conversion failed (HTTP ' + res.getStatusCode() + '): ' + snippet
            );
        }
        Map<String, Object> result =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Boolean success = result.get('success') == true;
        String url = (String) result.get('url');
        if (!success || String.isBlank(url)) {
            String err = (String) result.get('error');
            throw new AuraHandledException(
                'Lambda did not return a valid PDF URL. ' + (err != null ? 'Error: ' + err : '')
            );
        }
        return url;
    }
}
