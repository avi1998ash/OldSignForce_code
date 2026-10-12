/**
 * PDFGenerationService — server-side stamped-PDF rendering via Visualforce.
 *
 * Calls Page.StampedAgreementPDF.getContentAsPDF() and similar to produce
 * the post-completion stamped agreement and signing certificate PDFs, then
 * saves the resulting blobs to ContentVersion linked to the agreement.
 */
public with sharing class PDFGenerationService {

    public static Id generateSignedPDF(Id agreementId) {
        Agreement__c agr = [
            SELECT Id, Name FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE
        ];

        // ── Generate Stamped PDF (signed document with field values) ──
        List<Agreement_Document__c> oldStamped = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
            WITH USER_MODE
        ];
        if (!oldStamped.isEmpty()) Database.delete(oldStamped, true, AccessLevel.USER_MODE);

        PageReference stampedPage = Page.StampedAgreementPDF;
        stampedPage.getParameters().put('agreementId', agreementId);

        Blob stampedBlob;
        if (Test.isRunningTest()) {
            stampedBlob = Blob.valueOf('Stamped PDF');
        } else {
            stampedBlob = stampedPage.getContentAsPDF();
        }

        ContentVersion stampedCv = new ContentVersion();
        stampedCv.Title = agr.Name + ' - Signed Document';
        stampedCv.PathOnClient = agr.Name + '_Signed.pdf';
        stampedCv.VersionData = stampedBlob;
        stampedCv.IsMajorVersion = true;
        Database.insert(stampedCv, true, AccessLevel.USER_MODE);

        stampedCv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :stampedCv.Id WITH USER_MODE];

        ContentDocumentLink stampedCdl = new ContentDocumentLink();
        stampedCdl.ContentDocumentId = stampedCv.ContentDocumentId;
        stampedCdl.LinkedEntityId = agreementId;
        stampedCdl.ShareType = 'V';
        stampedCdl.Visibility = 'AllUsers';
        Database.insert(stampedCdl, true, AccessLevel.USER_MODE);

        Agreement_Document__c stampedDoc = new Agreement_Document__c();
        stampedDoc.Agreement__c = agreementId;
        stampedDoc.Name = agr.Name + ' - Signed Document';
        stampedDoc.Content_Version_ID__c = stampedCv.Id;
        stampedDoc.Document_Type__c = 'Stamped';
        Database.insert(stampedDoc, true, AccessLevel.USER_MODE);

        System.debug('SignForce: Stamped PDF saved = ' + stampedCv.ContentDocumentId);

        // ── Generate Certificate PDF (audit trail) ──
        List<Agreement_Document__c> oldCerts = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Signed'
            WITH USER_MODE
        ];
        if (!oldCerts.isEmpty()) Database.delete(oldCerts, true, AccessLevel.USER_MODE);

        PageReference certPage = Page.SignedAgreementPDF;
        certPage.getParameters().put('agreementId', agreementId);

        Blob certBlob;
        if (Test.isRunningTest()) {
            certBlob = Blob.valueOf('Certificate PDF');
        } else {
            certBlob = certPage.getContentAsPDF();
        }

        ContentVersion certCv = new ContentVersion();
        certCv.Title = agr.Name + ' - Signing Certificate';
        certCv.PathOnClient = agr.Name + '_Certificate.pdf';
        certCv.VersionData = certBlob;
        certCv.IsMajorVersion = true;
        Database.insert(certCv, true, AccessLevel.USER_MODE);

        certCv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :certCv.Id WITH USER_MODE];

        ContentDocumentLink certCdl = new ContentDocumentLink();
        certCdl.ContentDocumentId = certCv.ContentDocumentId;
        certCdl.LinkedEntityId = agreementId;
        certCdl.ShareType = 'V';
        certCdl.Visibility = 'AllUsers';
        Database.insert(certCdl, true, AccessLevel.USER_MODE);

        Agreement_Document__c certDoc = new Agreement_Document__c();
        certDoc.Agreement__c = agreementId;
        certDoc.Name = agr.Name + ' - Signing Certificate';
        certDoc.Content_Version_ID__c = certCv.Id;
        certDoc.Document_Type__c = 'Signed';
        Database.insert(certDoc, true, AccessLevel.USER_MODE);

        System.debug('SignForce: Certificate PDF saved = ' + certCv.ContentDocumentId);

        return certCv.ContentDocumentId;
    }

    /**
     * Generates ONLY the signing certificate (audit trail PDF), not the
     * stamped agreement. Use this when the Stamped PDF is being produced
     * by a separate path (e.g. Lambda) and you only need the certificate
     * for the completion email.
     *
     * Replaces any existing Certificate (Document_Type__c = 'Signed') record.
     */
    public static Id generateCertificateOnly(Id agreementId) {
        System.debug('SignForce CERT: ===== Starting generateCertificateOnly for ' + agreementId + ' =====');

        Agreement__c agr = [
            SELECT Id, Name FROM Agreement__c WHERE Id = :agreementId
            WITH USER_MODE
        ];

        // Remove any prior certificate so we don't accumulate stale audit trails.
        List<Agreement_Document__c> oldCerts = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Signed'
            WITH USER_MODE
        ];
        if (!oldCerts.isEmpty()) {
            System.debug('SignForce CERT: Deleting ' + oldCerts.size() + ' old cert records');
            Database.delete(oldCerts, true, AccessLevel.USER_MODE);
        }

        PageReference certPage = Page.SignedAgreementPDF;
        // CRITICAL FIX: must pass as String, not Id - VF param map is String/String
        certPage.getParameters().put('agreementId', String.valueOf(agreementId));

        Blob certBlob;
        if (Test.isRunningTest()) {
            certBlob = Blob.valueOf('Certificate PDF');
        } else {
            try {
                certBlob = certPage.getContentAsPDF();
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'SignForce CERT: getContentAsPDF failed: ' + e.getMessage());
                throw e;
            }
        }

        // Validate blob - a real PDF is at least ~1KB. Blank PDFs are typically 400-800 bytes.
        Integer blobSize = certBlob != null ? certBlob.size() : 0;
        System.debug('SignForce CERT: Blob size = ' + blobSize + ' bytes');
        if (blobSize < 1000 && !Test.isRunningTest()) {
            System.debug(LoggingLevel.WARN,
                'SignForce CERT: Suspiciously small blob (' + blobSize + ' bytes). ' +
                'Certificate may render blank. Check VF page diagnostics.');
        }

        ContentVersion certCv = new ContentVersion();
        certCv.Title = agr.Name + ' - Signing Certificate';
        certCv.PathOnClient = agr.Name + '_Certificate.pdf';
        certCv.VersionData = certBlob;
        certCv.IsMajorVersion = true;
        Database.insert(certCv, true, AccessLevel.USER_MODE);

        certCv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :certCv.Id WITH USER_MODE];

        ContentDocumentLink certCdl = new ContentDocumentLink();
        certCdl.ContentDocumentId = certCv.ContentDocumentId;
        certCdl.LinkedEntityId = agreementId;
        certCdl.ShareType = 'V';
        certCdl.Visibility = 'AllUsers';
        Database.insert(certCdl, true, AccessLevel.USER_MODE);

        Agreement_Document__c certDoc = new Agreement_Document__c();
        certDoc.Agreement__c = agreementId;
        certDoc.Name = agr.Name + ' - Signing Certificate';
        certDoc.Content_Version_ID__c = certCv.Id;
        certDoc.Document_Type__c = 'Signed';
        Database.insert(certDoc, true, AccessLevel.USER_MODE);

        System.debug('SignForce CERT: Certificate saved CV=' + certCv.ContentDocumentId + ' size=' + blobSize);
        return certCv.ContentDocumentId;
    }

    /**
     * Diagnostic helper. Run from Anonymous Apex to debug a blank certificate:
     *   Id agId = [SELECT Id FROM Agreement__c WHERE Status__c='Completed' LIMIT 1].Id;
     *   System.debug(PDFGenerationService.diagnosePDF(agId));
     */
    public static Map<String, Object> diagnosePDF(Id agreementId) {
        Map<String, Object> out = new Map<String, Object>();
        out.put('htmlSize', 0);
        out.put('pdfSize', 0);
        out.put('htmlPreview', null);
        out.put('error', null);

        // HTML render (catch separately)
        try {
            PageReference p = Page.SignedAgreementPDF;
            p.getParameters().put('agreementId', String.valueOf(agreementId));
            Blob htmlBlob = p.getContent();
            Integer rawSize = htmlBlob != null ? htmlBlob.size() : 0;
            out.put('htmlSize', rawSize);

            // Try UTF-8 first; if blob has binary/null bytes, fall back to base64
            String html;
            try {
                html = htmlBlob != null ? htmlBlob.toString() : '';
            } catch (Exception utfEx) {
                // Page produced non-UTF8 output. Read as base64 + raw bytes so we can see what came back.
                String b64 = htmlBlob != null ? EncodingUtil.base64Encode(htmlBlob) : '';
                html = '[NON-UTF8 OUTPUT, base64 preview]: ' + (b64.length() > 1500 ? b64.substring(0, 1500) : b64);
                out.put('htmlEncodingError', utfEx.getMessage());
            }
            out.put('htmlPreview', html.length() > 2000 ? html.substring(0, 2000) : html);
        } catch (Exception e) {
            out.put('htmlError', e.getMessage() + ' :: ' + e.getStackTraceString());
        }

        // PDF render (separate try so PDF errors don't stop HTML diagnostics)
        try {
            PageReference p2 = Page.SignedAgreementPDF;
            p2.getParameters().put('agreementId', String.valueOf(agreementId));
            Blob pdfBlob = p2.getContentAsPDF();
            out.put('pdfSize', pdfBlob != null ? pdfBlob.size() : 0);
        } catch (Exception e) {
            out.put('pdfError', e.getMessage() + ' :: ' + e.getStackTraceString());
        }

        // Also test the controller in isolation (without the VF page)
        try {
            PageReference p3 = Page.SignedAgreementPDF;
            p3.getParameters().put('agreementId', String.valueOf(agreementId));
            Test.setCurrentPage(p3);
            // Cannot instantiate the controller directly outside test context here.
            // Instead, just confirm agreement is visible from this context.
            List<Agreement__c> chk = [
                SELECT Id, Name, Status__c, Envelope_ID__c
                FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE LIMIT 1
            ];
            out.put('agreementVisible', !chk.isEmpty());
            if (!chk.isEmpty()) {
                out.put('agreementName', chk[0].Name);
                out.put('agreementStatus', chk[0].Status__c);
            }
            Integer signerCount = [SELECT COUNT() FROM Signer__c WHERE Agreement__c = :agreementId WITH USER_MODE];
            out.put('signerCount', signerCount);
        } catch (Exception e) {
            out.put('contextError', e.getMessage());
        }

        return out;
    }

    public static Messaging.EmailFileAttachment getPDFAttachment(Id agreementId) {
        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c, Document_Type__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c IN ('Stamped', 'Signed')
            WITH USER_MODE
            ORDER BY Document_Type__c ASC, CreatedDate DESC
        ];
        if (docs.isEmpty()) return null;

        Agreement_Document__c selected = docs[0];
        for (Agreement_Document__c d : docs) {
            if (d.Document_Type__c == 'Stamped') { selected = d; break; }
        }

        return buildAttachment(selected.Content_Version_ID__c);
    }

    public static List<Messaging.EmailFileAttachment> getAllAttachments(Id agreementId) {
        List<Messaging.EmailFileAttachment> attachments = new List<Messaging.EmailFileAttachment>();

        // Signing certificate (generated by trigger)
        List<Agreement_Document__c> certDocs = [
            SELECT Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Signed'
            WITH USER_MODE
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (!certDocs.isEmpty()) {
            attachments.add(buildAttachment(certDocs[0].Content_Version_ID__c));
        }

        // Fallback to original if nothing found
        if (attachments.isEmpty()) {
            List<Agreement_Document__c> origDocs = [
                SELECT Content_Version_ID__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId
                AND Document_Type__c = 'Original'
                WITH USER_MODE
                LIMIT 1
            ];
            if (!origDocs.isEmpty()) {
                attachments.add(buildAttachment(origDocs[0].Content_Version_ID__c));
            }
        }

        return attachments;
    }

    private static Messaging.EmailFileAttachment buildAttachment(String cvId) {
        ContentVersion cv = [SELECT Title, VersionData FROM ContentVersion WHERE Id = :cvId WITH USER_MODE];
        Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
        att.setFileName(cv.Title + '.pdf');
        att.setBody(cv.VersionData);
        att.setContentType('application/pdf');
        return att;
    }
}