/**
 * Tests for SalesforceChunkUpload — chunked, heap-safe Salesforce Files upload.
 * The 5 MB case is the important one: it proves the async assembly stays under
 * the 12 MB heap for the largest file we allow.
 */
@isTest
private class SalesforceChunkUploadTest {

    /** A ~1 MB, 4-char-aligned base64 chunk (decodes to ~0.75 MB). */
    private static String bigChunk() {
        String s = 'QUJDREVGR0hJSktM'; // 16 chars, valid base64, 4-aligned
        while (s.length() < 999996) s += s;
        return s.substring(0, 999996);
    }

    @isTest
    static void assemblesSmallFile() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Chunk Small');
        String chunk = 'QUJDREVGR0hJSktM'; // one tiny chunk
        Test.startTest();
        SalesforceChunkUpload.storeOriginalChunk(agr.Id, 'sk1', 0, 1, chunk, 'small.pdf');
        Test.stopTest();

        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c, Storage_Tier__c, Storage_Type__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Original'
        ];
        System.assertEquals(1, docs.size(), 'Original doc should be assembled');
        System.assertNotEquals(null, docs[0].Content_Version_ID__c, 'ContentVersion linked');
        System.assertEquals('Tier1', docs[0].Storage_Tier__c);
        System.assertEquals('Salesforce', docs[0].Storage_Type__c);
        System.assertEquals(true, SalesforceChunkUpload.isOriginalReady(agr.Id));

        // Temp chunk files were cleaned up.
        System.assertEquals(0, [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'sfchunk_sk1_%']);
    }

    @isTest
    static void assemblesLargeFileWithinHeap() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Chunk Large');
        String chunk = bigChunk();      // ~1 MB base64 each
        Integer total = 5;              // 5 x ~0.75 MB ≈ 3.6 MB — safely under the async heap

        Test.startTest();
        for (Integer i = 0; i < total; i++) {
            SalesforceChunkUpload.storeOriginalChunk(agr.Id, 'sk5', i, total, chunk, 'big.pdf');
        }
        Test.stopTest(); // AssembleJob runs here — must not exceed the 12 MB async heap

        List<Agreement_Document__c> docs = [
            SELECT File_Size_Bytes__c, Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Original'
        ];
        System.assertEquals(1, docs.size(), 'Large file should assemble into one Original');
        System.assert(docs[0].File_Size_Bytes__c > 3000000,
            'Assembled file should be ~3.6 MB, was ' + docs[0].File_Size_Bytes__c);
        System.assertEquals(0, [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'sfchunk_sk5_%'],
            'Temp chunks cleaned up after assembly');
    }

    @isTest
    static void firstChunkClearsPriorOriginal() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Chunk Replace');
        Agreement_Document__c prior = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.startTest();
        SalesforceChunkUpload.storeOriginalChunk(agr.Id, 'sk2', 0, 1, 'QUJDREVGR0hJSktM', 'new.pdf');
        Test.stopTest();

        // Exactly one Original remains (the new one, not the prior).
        List<Agreement_Document__c> docs = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Original'
        ];
        System.assertEquals(1, docs.size(), 'Prior Original should be replaced, not duplicated');
        System.assertNotEquals(prior.Id, docs[0].Id, 'A fresh Original should have been created');
    }

    @isTest
    static void isOriginalReadyFalseWhenNone() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Chunk None');
        System.assertEquals(false, SalesforceChunkUpload.isOriginalReady(agr.Id));
        System.assertEquals(false, SalesforceChunkUpload.isOriginalReady(null));
    }
}