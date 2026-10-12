/**
 * TestDataFactory — reusable test data builders for SignForce.
 *
 * Used across every test class in the package. Keep it minimal: only add
 * methods that are reused in 2+ test classes. One-off setups go inline.
 *
 * SHARING: @isTest implicitly runs as system, so sharing mode doesn't
 * matter here. Default to `with sharing` for cleanliness.
 *
 * USAGE
 *
 *   Agreement__c agr = TestDataFactory.createDraftAgreement('Test NDA');
 *   Signer__c signer = TestDataFactory.createSignerWithToken(
 *       agr.Id, 'alice@example.com'
 *   );
 *   Signature_Field__c sig = TestDataFactory.createSignatureField(
 *       agr.Id, signer.Id, 1, 100, 200
 *   );
 */
@isTest
public with sharing class TestDataFactory {

    /**
     * AgreementTrigger no longer skips stamping when Test.isRunningTest(); it queues the @future
     * Lambda stamp whenever an Agreement__c moves to Completed unless
     * AgreementControllerGuest.suppressCompletionStampTrigger is set. A test that completes an agreement
     * but does not exercise stamping calls this first, so no @future callout runs at Test.stopTest().
     * (Same behaviour those tests always had; the switch just moved out of production code.)
     */
    public static void suppressCompletionStamp() {
        AgreementControllerGuest.suppressCompletionStampTrigger = true;
    }

    /**
     * Create a Draft agreement with sensible defaults. Caller can override
     * by mutating the returned record before any subsequent assertions.
     */
    public static Agreement__c createDraftAgreement(String name) {
        Agreement__c agr = new Agreement__c();
        agr.Name = name;
        agr.Status__c = 'Draft';
        agr.Agreement_Type__c = 'NDA';
        agr.Signing_Order__c = 'Sequential';
        agr.Storage_Location__c = 'Salesforce';
        agr.Is_Template__c = false;
        insert agr;
        return agr;
    }

    /**
     * Create a Sent (in-progress) agreement — useful when the test needs
     * to exercise behavior after sendForSignature has run.
     */
    public static Agreement__c createSentAgreement(String name) {
        Agreement__c agr = createDraftAgreement(name);
        agr.Status__c = 'Sent';
        agr.Sent_Date__c = DateTime.now();
        agr.Envelope_ID__c = 'env-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 16);
        update agr;
        return agr;
    }

    /**
     * Create a Signer with a fresh 32-char token and a 0 view count
     * (matches the state right after sendForSignature).
     */
    public static Signer__c createSignerWithToken(Id agreementId, String email) {
        Signer__c s = new Signer__c();
        s.Agreement__c = agreementId;
        s.Name = email.substringBefore('@');
        s.Email__c = email;
        s.Role__c = 'Signer';
        s.Status__c = 'Pending';
        s.Signing_Order__c = 1;
        s.Access_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        s.Token_Created_Date__c = DateTime.now();
        s.Token_View_Count__c = 0;
        s.Token_Expired__c = false;
        insert s;
        return s;
    }

    /**
     * Create a Signer in any specific state (used for negative tests:
     * expired token, signed status, declined status, etc).
     */
    public static Signer__c createSignerInState(
        Id agreementId,
        String email,
        String status,
        DateTime tokenCreatedDate,
        Boolean tokenExpired,
        Integer viewCount
    ) {
        Signer__c s = createSignerWithToken(agreementId, email);
        s.Status__c = status;
        s.Token_Created_Date__c = tokenCreatedDate;
        s.Token_Expired__c = tokenExpired;
        s.Token_View_Count__c = viewCount;
        update s;
        return s;
    }

    /**
     * Create a Signature_Field__c assigned to a signer.
     */
    public static Signature_Field__c createSignatureField(
        Id agreementId, Id signerId, Integer page, Decimal x, Decimal y
    ) {
        Signature_Field__c f = new Signature_Field__c();
        f.Agreement__c = agreementId;
        f.Assigned_Signer__c = signerId;
        f.Field_Type__c = 'Signature';
        f.Field_Label__c = 'Signature';
        f.Page_Number__c = page;
        f.X_Position__c = x;
        f.Y_Position__c = y;
        f.Width__c = 150;
        f.Height__c = 50;
        f.Page_Width__c = 762;
        f.Is_Required__c = true;
        f.Is_Completed__c = false;
        insert f;
        return f;
    }

    /**
     * Create an Original Agreement_Document__c (Tier1) for the agreement,
     * with a ContentVersion attached so PDF preview paths work.
     */
    public static Agreement_Document__c createTier1OriginalDoc(Id agreementId) {
        ContentVersion cv = new ContentVersion();
        cv.Title = 'Test Document';
        cv.PathOnClient = 'test.pdf';
        cv.VersionData = Blob.valueOf('fake-pdf-bytes');
        cv.FirstPublishLocationId = agreementId;
        insert cv;

        ContentVersion inserted = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c = agreementId;
        doc.Name = 'Test Document';
        doc.Content_Version_ID__c = inserted.Id;
        doc.Document_Type__c = 'Original';
        doc.Storage_Tier__c = 'Tier1';
        doc.File_Size_Bytes__c = 14;
        insert doc;
        return doc;
    }

    /**
     * Create an S3-backed Original Agreement_Document__c (Tier2/Tier3).
     * No ContentVersion; the bytes live in S3 in production.
     */
    public static Agreement_Document__c createS3OriginalDoc(
        Id agreementId, String tier
    ) {
        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c = agreementId;
        doc.Name = 'Test S3 Document';
        doc.Document_Type__c = 'Original';
        doc.Storage_Tier__c = String.isBlank(tier) ? 'Tier2' : tier;
        doc.S3_Document_ID__c = 'test_s3_doc_' + DateTime.now().getTime();
        doc.S3_Preview_URL__c = 'https://example.s3.amazonaws.com/' + doc.S3_Document_ID__c;
        doc.File_Size_Bytes__c = 1048576;
        insert doc;
        return doc;
    }
}