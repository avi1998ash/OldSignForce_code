/**
 * Visualforce controller for generating signed PDF with signature fields
 * overlaid on the original document.
 *
 * SHARING: WITHOUT SHARING — System-context VF page rendering. Not @AuraEnabled.
 * Called from server-side stamp flows where the original user's sharing context
 * is not available.
 *
 * SECURITY MODEL:
 *   - All SOQL uses — CRUD/FLS enforced at the statement level.
 *   - No DML in this class (read-only rendering).
 **/
global with sharing class SignedDocumentPDFController {

    public String envelopeId { get; set; }
    public List<PageWrapper> pages { get; set; }

    // PDF page dimensions (A4 in points: 595 x 842)
    private static final Decimal PDF_WIDTH_PT = 595.0;

    public class PageWrapper {
        public Integer pageNum { get; set; }
        public String base64Image { get; set; }
        public List<FieldWrapper> fields { get; set; }
    }

    public class FieldWrapper {
        public String positionStyle { get; set; }
        public String displayValue { get; set; }
        public String fontFamily { get; set; }
        public String fontSize { get; set; }
        public String signerName { get; set; }
        public String certificateId { get; set; }
        public String signedDate { get; set; }
        public String certStampStyle { get; set; }
        public Boolean isTypedSignature { get; set; }
        public Boolean isUploadSignature { get; set; }
        public Boolean isDrawSignature { get; set; }
        public Boolean isTextField { get; set; }
        public Boolean isCheckbox { get; set; }
        public Boolean showCertStamp { get; set; }
    }

    public SignedDocumentPDFController() {
        pages = new List<PageWrapper>();
        String agreementId = ApexPages.currentPage().getParameters().get('agreementId');
        if (String.isBlank(agreementId)) return;

        // Get agreement
        Agreement__c agr = GuestSigningApiInternal.sdAgreement(agreementId);
        envelopeId = agr.Envelope_ID__c;

        // Get original document
        List<Agreement_Document__c> docs = GuestSigningApiInternal.sdOriginalDoc(agreementId);
        if (docs.isEmpty()) return;

        ContentVersion cv = GuestSigningApiInternal.sdContentVersion(docs[0].Content_Version_ID__c);

        // Get all completed fields
        List<Signature_Field__c> allFields = GuestSigningApiInternal.sdFields(agreementId);

        // Get saved signatures for draw type
        Map<String, Saved_Signature__c> sigMap = new Map<String, Saved_Signature__c>();
        for (Signature_Field__c f : allFields) {
            if (f.Assigned_Signer__r != null && f.Assigned_Signer__r.Email__c != null) {
                String email = f.Assigned_Signer__r.Email__c;
                if (!sigMap.containsKey(email)) {
                    List<Saved_Signature__c> sigs = GuestSigningApiInternal.savedSignatureFor(email);
                    if (!sigs.isEmpty()) sigMap.put(email, sigs[0]);
                }
            }
        }

        // Get total pages from PDF using rendition approach
        // We'll use base64 of the entire PDF and render per-page via VF
        String pdfBase64 = EncodingUtil.base64Encode(cv.VersionData);

        // Since we can't split PDF pages in Apex, we render the whole PDF as one image
        // and overlay fields. The VF page will handle pagination via page-break.
        // For proper per-page rendering, we use a single page approach with SVGZ renditions.

        // Get number of pages by checking max page number from fields, or default to 1
        Integer totalPages = 1;
        for (Signature_Field__c f : allFields) {
            if (f.Page_Number__c != null && f.Page_Number__c > totalPages) {
                totalPages = (Integer) f.Page_Number__c;
            }
        }

        // Try to get renditions for each page
        String cvId = docs[0].Content_Version_ID__c;
        for (Integer i = 1; i <= totalPages; i++) {
            PageWrapper pw = new PageWrapper();
            pw.pageNum = i;
            pw.base64Image = ''; // Will be set below
            pw.fields = new List<FieldWrapper>();

            // Add fields for this page
            for (Signature_Field__c f : allFields) {
                Integer fieldPage = (f.Page_Number__c != null) ? (Integer) f.Page_Number__c : 1;
                if (fieldPage != i) continue;
                if (!f.Is_Completed__c) continue;

                FieldWrapper fw = buildFieldWrapper(f, sigMap);
                pw.fields.add(fw);
            }

            pages.add(pw);
        }

        // Set base64 for the full PDF (first page only for image rendering)
        // Since VF renderAs=pdf can't use JS, we set the PDF as a single base64
        if (!pages.isEmpty()) {
            pages[0].base64Image = pdfBase64;
        }
    }

    private FieldWrapper buildFieldWrapper(Signature_Field__c f, Map<String, Saved_Signature__c> sigMap) {
        FieldWrapper fw = new FieldWrapper();
        fw.isTypedSignature = false;
        fw.isUploadSignature = false;
        fw.isDrawSignature = false;
        fw.isTextField = false;
        fw.isCheckbox = false;
        fw.showCertStamp = false;

        // Calculate position as percentage of page width for responsive rendering
        Decimal pageWidth = (f.Page_Width__c != null && f.Page_Width__c > 0) ? f.Page_Width__c : 612;
        Decimal xPct = ((f.X_Position__c != null ? f.X_Position__c : 0) / pageWidth) * 100;
        Decimal yPct = ((f.Y_Position__c != null ? f.Y_Position__c : 0) / pageWidth) * 100; // Use width for aspect ratio
        Decimal wPct = ((f.Width__c != null ? f.Width__c : 150) / pageWidth) * 100;
        Decimal hPct = ((f.Height__c != null ? f.Height__c : 50) / pageWidth) * 100;

        fw.positionStyle = 'left:' + xPct + '%;top:' + yPct + '%;width:' + wPct + '%;height:' + hPct + '%;';

        String val = f.Field_Value__c != null ? f.Field_Value__c : '';
        fw.displayValue = val;
        fw.signerName = f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Name : '';
        fw.fontFamily = 'Dancing Script';
        fw.fontSize = '18';

        if (f.Field_Type__c == 'Signature' || f.Field_Type__c == 'Initial') {
            fw.showCertStamp = true;
            fw.certificateId = f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Signature_Certificate_ID__c : '';
            fw.signedDate = f.Assigned_Signer__r != null && f.Assigned_Signer__r.Signed_Date__c != null
                ? f.Assigned_Signer__r.Signed_Date__c.format('MMM dd, yyyy HH:mm')
                : '';

            // Certificate stamp position (below the signature)
            Decimal certTop = yPct + hPct;
            fw.certStampStyle = 'left:' + xPct + '%;top:' + certTop + '%;width:' + wPct + '%;';

            if (val.startsWith('[')) {
                // Draw signature — render as signer name in cursive
                fw.isDrawSignature = true;
                fw.fontSize = String.valueOf(Math.min(24, (Integer)(f.Height__c != null ? f.Height__c * 0.6 : 18)));
            } else if (val.startsWith('typed:')) {
                fw.isTypedSignature = true;
                List<String> parts = val.split(':');
                fw.displayValue = parts.size() > 1 ? parts[1] : fw.signerName;
                fw.fontFamily = parts.size() > 2 ? parts[2] : 'Dancing Script';
                fw.fontSize = String.valueOf(Math.min(28, (Integer)(f.Height__c != null ? f.Height__c * 0.6 : 22)));
            } else if (val.startsWith('data:')) {
                fw.isUploadSignature = true;
            }
        } else if (f.Field_Type__c == 'Checkbox') {
            fw.isCheckbox = true;
        } else {
            fw.isTextField = true;
        }

        return fw;
    }
}