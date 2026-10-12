/**
 * @description : Controller for stamping fields onto original PDF
 * @author      : SignForce
 *
 * Sharing: left without sharing rather than guessed into "with sharing".
 * This controller backs Stampedpdf.page, whose only in-repo caller
 * (GenerateStampedPDFQueueable) is itself not called by anything in
 * production (see that class). Neither this class nor Stampedpdf.page is
 * granted in SignForce_Guest_User_Access, SignForce_User, or any profile —
 * StampedAgreementPDFController/SignedAgreementPDFController are the
 * classes actually granted for the equivalent guest-facing flow today. That
 * makes this page look superseded/orphaned rather than live, but with no
 * runtime path to confirm that with certainty, changing its sharing mode is
 * not attempted here.
**/
global with sharing class StampedPDFController {

    public String agreementId { get; set; }
    public String pdfBase64 { get; set; }
    public String fieldsJson { get; set; }
    public String envelopeId { get; set; }

    public StampedPDFController() {
        agreementId = ApexPages.currentPage().getParameters().get('agreementId');
        if (String.isBlank(agreementId)) return;

        // Get envelope ID
        Agreement__c agr = [
            SELECT Envelope_ID__c FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE
        ];
        envelopeId = agr.Envelope_ID__c != null ? agr.Envelope_ID__c : '';

        // Get original PDF as base64
        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Original'
            WITH USER_MODE
            LIMIT 1
        ];
        if (!docs.isEmpty()) {
            ContentVersion cv = [
                SELECT VersionData FROM ContentVersion
                WHERE Id = :docs[0].Content_Version_ID__c
                WITH USER_MODE
            ];
            pdfBase64 = EncodingUtil.base64Encode(cv.VersionData);
        } else {
            pdfBase64 = '';
        }

        // Get all completed fields with signer info
        List<Signature_Field__c> fields = [
            SELECT Id, Field_Type__c, Field_Value__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Page_Width__c, Is_Completed__c,
                   Assigned_Signer__c, Assigned_Signer__r.Name,
                   Assigned_Signer__r.Email__c,
                   Assigned_Signer__r.Signature_Certificate_ID__c,
                   Assigned_Signer__r.Signed_Date__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agreementId
            WITH USER_MODE
            ORDER BY Page_Number__c ASC
        ];

        // Build JSON for JavaScript
        List<Map<String, Object>> fieldList = new List<Map<String, Object>>();
        for (Signature_Field__c f : fields) {
            Map<String, Object> fm = new Map<String, Object>();
            fm.put('fieldType', f.Field_Type__c);
            fm.put('value', f.Field_Value__c != null ? f.Field_Value__c : '');
            fm.put('pageNumber', f.Page_Number__c != null ? (Integer)f.Page_Number__c : 1);
            fm.put('xPos', f.X_Position__c);
            fm.put('yPos', f.Y_Position__c);
            fm.put('width', f.Width__c);
            fm.put('height', f.Height__c);
            fm.put('pageWidth', f.Page_Width__c);
            fm.put('isCompleted', f.Is_Completed__c);
            fm.put('signerName', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Name : '');
            fm.put('certId', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Signature_Certificate_ID__c : '');
            fm.put('signedDate', f.Assigned_Signer__r != null && f.Assigned_Signer__r.Signed_Date__c != null
                ? f.Assigned_Signer__r.Signed_Date__c.format('MMM dd, yyyy HH:mm') : '');
            fieldList.add(fm);
        }

        fieldsJson = JSON.serialize(fieldList);
    }

    @RemoteAction
    global static String saveStampedPDF(String agreementId, String pdfBase64Data) {
        try {
            Agreement__c agr = [SELECT Id, Name FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE];

            Blob pdfBlob = EncodingUtil.base64Decode(pdfBase64Data);

            // Delete old stamped document if exists
            List<Agreement_Document__c> oldDocs = [
                SELECT Id, Content_Version_ID__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
                WITH USER_MODE
            ];
            if (!oldDocs.isEmpty()) {
                Database.delete(oldDocs, true, AccessLevel.USER_MODE);
            }

            ContentVersion cv = new ContentVersion();
            cv.Title = agr.Name + ' - Signed Document';
            cv.PathOnClient = agr.Name + '_Signed.pdf';
            cv.VersionData = pdfBlob;
            cv.FirstPublishLocationId = agreementId;
            Database.insert(cv, true, AccessLevel.USER_MODE);

            ContentVersion inserted = [
                SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE
            ];

            Agreement_Document__c doc = new Agreement_Document__c();
            doc.Agreement__c = agreementId;
            doc.Name = agr.Name + ' - Signed Document';
            doc.Content_Version_ID__c = inserted.Id;
            doc.Document_Type__c = 'Stamped';
            Database.insert(doc, true, AccessLevel.USER_MODE);

            return 'OK';
        } catch(Exception e) {
            return 'ERROR: ' + e.getMessage();
        }
    }
}