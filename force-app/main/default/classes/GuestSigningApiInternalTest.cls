/**
 * GuestSigningApiInternalTest - coverage for GuestSigningApiInternal, the internal-user (`with sharing`)
 * data-access helpers split out of GuestSigningApi: the SignedDocumentPDF / StampedAgreementPDF helpers
 * (moved), and the PDF-preview and shared helpers (copied).
 */
@isTest
private class GuestSigningApiInternalTest {

    private static Agreement__c agreementWithSigner(String name) {
        TestDataFactory.suppressCompletionStamp();
        return TestDataFactory.createSentAgreement(name);
    }

    // ── helpers that need no file ──────────────────────────────────────────

    @isTest
    static void agreementScopedHelpers_returnTheAgreementsRows() {
        Agreement__c agr = agreementWithSigner('Internal Helpers');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'internal.helper@example.com');
        Signature_Field__c sig = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        sig.Is_Completed__c = true;
        sig.Field_Value__c = 'data:image/png;base64,AAA';
        update sig;
        Signature_Field__c txt = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 300);
        txt.Field_Type__c = 'Full Name';
        txt.Field_Label__c = 'Company';
        txt.Is_Completed__c = true;
        txt.Field_Value__c = 'Acme';
        update txt;

        System.assertEquals(agr.Id, GuestSigningApiInternal.sdAgreement(agr.Id).Id);
        System.assertEquals(agr.Id, GuestSigningApiInternal.stAgreement(agr.Id).Id);
        System.assertEquals(2, GuestSigningApiInternal.sdFields(agr.Id).size());
        System.assert(!GuestSigningApiInternal.stSigners(agr.Id).isEmpty());
        System.assertEquals(1, GuestSigningApiInternal.stSignatureField(agr.Id, signer.Id).size());
        List<Signature_Field__c> values = GuestSigningApiInternal.stValueFields(agr.Id);
        System.assertEquals(1, values.size());
        System.assertEquals('Acme', values[0].Field_Value__c);
    }

    @isTest
    static void sharedHelpers_auditSignatureTimezoneAndUser() {
        Agreement__c agr = agreementWithSigner('Internal Shared');
        AuditTrailService.log(agr.Id, 'Helper Test', 'h@example.com', '1.2.3.4', null);
        System.assert(!GuestSigningApiInternal.auditRowsFor(agr.Id).isEmpty());

        insert new Saved_Signature__c(Email__c = 'saved@example.com', Signature_Data__c = 'Type:Jane:Dancing Script', Signature_Type__c = 'Type');
        List<Saved_Signature__c> saved = GuestSigningApiInternal.savedSignatureFor('saved@example.com');
        System.assertEquals(1, saved.size());
        System.assertEquals(0, GuestSigningApiInternal.savedSignatureFor('nobody@example.com').size());

        System.assert(String.isNotBlank(GuestSigningApiInternal.orgTimeZone()));
        System.assertEquals(1, GuestSigningApiInternal.userName(UserInfo.getUserId()).size());
    }

    // ── helpers that read a ContentVersion ─────────────────────────────────

    private static ContentVersion cv(String title, Blob data) {
        ContentVersion v = new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = data, IsMajorVersion = true);
        insert v;
        return [SELECT Id FROM ContentVersion WHERE Id = :v.Id];
    }

    @isTest
    static void signedDocumentHelpers_originalDocAndContentVersion() {
        Agreement__c agr = agreementWithSigner('Internal Original');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        System.assertEquals(1, GuestSigningApiInternal.sdOriginalDoc(agr.Id).size());
        ContentVersion v = GuestSigningApiInternal.sdContentVersion(doc.Content_Version_ID__c);
        System.assertNotEquals(null, v.VersionData);
    }

    @isTest
    static void pdfHelpers_base64InfoChunkAndDistribution() {
        ContentVersion v = cv('Internal PDF', Blob.valueOf('small pdf bytes'));
        System.assertEquals(EncodingUtil.base64Encode(Blob.valueOf('small pdf bytes')), GuestSigningApiInternal.pdfBase64(v.Id));
        Map<String, Object> info = GuestSigningApiInternal.pdfInfo(v.Id);
        System.assertEquals(1, info.get('totalChunks'));
        System.assertEquals(null, GuestSigningApiInternal.pdfDistributionUrl(v.Id));
        System.assertEquals(EncodingUtil.base64Encode(Blob.valueOf('small pdf bytes')), GuestSigningApiInternal.pdfChunk(v.Id, 0));
        System.assertEquals('', GuestSigningApiInternal.pdfChunk(v.Id, 100));
        // creates the ContentDistribution, then a second call reuses it
        String first = GuestSigningApiInternal.pdfCreateDistributionUrl(v.Id);
        String second = GuestSigningApiInternal.pdfCreateDistributionUrl(v.Id);
        System.assertEquals(first, second);
        System.assertEquals(first, GuestSigningApiInternal.pdfDistributionUrl(v.Id));
    }
}
