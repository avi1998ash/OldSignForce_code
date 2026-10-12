/**
 * AgreementCompletionHandler — RETIRED. Body commented out, not deleted.
 *
 * Superseded by GuestSigningApi.runStampingAndEmailAsync (guest signing)
 * and AgreementController.generateStampedPDFServerAsync (in-org signing), which
 * are what the live completion flow actually calls.
 *
 * Confirmed unreachable before retiring it:
 *   - no production caller anywhere in the repo; the only references were its own
 *     test class and the Agentforce_SignForce_User permission set,
 *   - that permission set belongs to the Agentforce engine, which is disabled.
 *
 * Kept as an empty class rather than deleted because this ships in a managed
 * package: removing a class is awkward to reverse once a version is released,
 * and leaving the shell costs nothing.
 *
 * The implementation is preserved verbatim below. If it is ever revived, note
 * that generateStampedPDFViaCallout passes a session id in a Cookie header to
 * call a Visualforce page over HTTP — a pattern this codebase has since moved
 * away from, and one the security scanner flags. The live stamping path calls
 * the Lambda directly instead.
 */
public with sharing class AgreementCompletionHandler {

    // Intentionally empty. Retired implementation retained below for reference.

    /*
    public static void handleCompletion(Id agreementId) {
        generateCertificateAndEmail(agreementId);
    }

    @future(callout=true)
    public static void generateCertificateAndEmail(Id agreementId) {
        try {
            System.debug('SignForce: Starting completion handler for ' + agreementId);

            // Step 1a: Generate STAMPED PDF via Lambda (signed agreement with field values)
            generateStampedPDFViaCallout(agreementId);
            System.debug('SignForce: Stamped PDF callout initiated');

            // Step 1b: Generate the signing CERTIFICATE (audit trail) via VF page.
            // This is what produces the second attachment in completion emails.
            // We use the Certificate-only path so we don't duplicate the Stamped PDF.
            try {
                PDFGenerationService.generateCertificateOnly(agreementId);
                System.debug('SignForce: Certificate PDF generated and saved');
            } catch(Exception certEx) {
                System.debug('SignForce: Certificate generation failed (non-fatal): ' + certEx.getMessage());
            }

            // Step 1.5: Push completed documents to enabled Cloud Storage (Google Drive, Box, SharePoint, etc.)
            try {
                IntegrationService.pushAgreementDocuments(agreementId);
                System.debug('SignForce: Stamped PDF pushed to cloud storage integrations');
            } catch(Exception cloudEx) {
                System.debug('SignForce: Cloud push failed (non-fatal): ' + cloudEx.getMessage());
            }

            // Step 2: Send completion emails with both attachments (Stamped + Certificate)
            AgreementService.sendCompletionEmailsPublic(agreementId);
            System.debug('SignForce: Completion emails sent');

        } catch(Exception e) {
            System.debug('SignForce ERROR: ' + e.getMessage()
                + ' | Line: ' + e.getLineNumber()
                + ' | Stack: ' + e.getStackTraceString());
        }
    }

    private static void generateStampedPDFViaCallout(Id agreementId) {
        try {
            // Get session ID for authenticated callout
            String sessionId = UserInfo.getSessionId();
            String orgUrl = URL.getOrgDomainUrl().toExternalForm();
            // Page.X.getUrl() emits the namespaced path (/apex/ns__StampedPDF) in a
            // managed package; a hardcoded '/apex/StampedPDF' 404s in subscriber orgs.
            String vfUrl = orgUrl + Page.StampedAgreementPDF.getUrl() + '?agreementId=' + agreementId;

            HttpRequest req = new HttpRequest();
            req.setEndpoint(vfUrl);
            req.setMethod('GET');
            req.setHeader('Cookie', 'sid=' + sessionId);
            req.setTimeout(120000); // 2 minutes

            Http http = new Http();
            HttpResponse res = http.send(req);
            System.debug('SignForce: Stamped PDF VF callout status = ' + res.getStatusCode());
        } catch(Exception e) {
            System.debug('SignForce: Stamped PDF callout error = ' + e.getMessage());
        }
    }
    */
}