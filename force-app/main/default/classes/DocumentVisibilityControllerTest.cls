/**
 * DocumentVisibilityControllerTest — full coverage for all 4 @AuraEnabled
 * methods on DocumentVisibilityController.
 *
 * Target: 56% → 90%+
 *
 * Methods covered:
 *   - getVisibilityMatrix
 *   - updateVisibility (insert + update branches)
 *   - canSignerViewDocument (no record + record-exists branches)
 *   - initializeVisibility (fresh + idempotent branches)
 */
@isTest(SeeAllData=false)
private class DocumentVisibilityControllerTest {

    // ═════════════════════════════════════════════════════════════════════
    //  getVisibilityMatrix
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getVisibilityMatrix_noDocsNoSigners_returnsEmptyLists() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Vis Empty');

        Test.startTest();
        Map<String, Object> data = DocumentVisibilityController.getVisibilityMatrix(agr.Id);
        Test.stopTest();

        Assert.isNotNull(data);
        Assert.isTrue(data.containsKey('documents'));
        Assert.isTrue(data.containsKey('signers'));
        Assert.isTrue(data.containsKey('matrix'));

        List<Object> docs = (List<Object>) data.get('documents');
        List<Object> signers = (List<Object>) data.get('signers');
        List<Object> matrix = (List<Object>) data.get('matrix');

        Assert.areEqual(0, docs.size());
        Assert.areEqual(0, signers.size());
        Assert.areEqual(0, matrix.size());
    }

    @isTest
    static void getVisibilityMatrix_withDocsAndSigners_buildsFullMatrix() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Vis Full Matrix');
        // A single Original is the normal post-purge (BUG-039) state; the grid
        // surfaces exactly that one doc across all signers.
        Agreement_Document__c doc1 = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Signer__c s1 = TestDataFactory.createSignerWithToken(agr.Id, 'a@example.com');
        Signer__c s2 = TestDataFactory.createSignerWithToken(agr.Id, 'b@example.com');

        Test.startTest();
        Map<String, Object> data = DocumentVisibilityController.getVisibilityMatrix(agr.Id);
        Test.stopTest();

        List<Object> docs = (List<Object>) data.get('documents');
        List<Object> signers = (List<Object>) data.get('signers');
        List<Object> matrix = (List<Object>) data.get('matrix');

        Assert.areEqual(1, docs.size(), 'Exactly one Original doc expected');
        Assert.areEqual(2, signers.size(), 'Two signers expected');
        Assert.areEqual(2, matrix.size(),
            'Matrix should be 1 doc × 2 signers = 2 cells');

        // Each cell should default canView=true (no access records exist)
        for (Object cellObj : matrix) {
            Map<String, Object> cell = (Map<String, Object>) cellObj;
            Assert.areEqual(true, cell.get('canView'),
                'Default visibility should be true when no access records exist');
            Assert.isNotNull(cell.get('docId'));
            Assert.isNotNull(cell.get('signerId'));
            Assert.isNotNull(cell.get('docName'));
            Assert.isNotNull(cell.get('signerName'));
        }
    }

    @isTest
    static void getVisibilityMatrix_multipleOriginals_surfacesNewestOnly() {
        // Edge case: if more than one Original somehow exists, the grid must
        // resolve to the newest (DESC LIMIT 1) so it never points at a replaced
        // file. (Normal flow purges duplicates via DocumentService BUG-039.)
        Agreement__c agr = TestDataFactory.createSentAgreement('Vis Multi Original');
        Agreement_Document__c older = TestDataFactory.createTier1OriginalDoc(agr.Id);
        // Force a deterministically-earlier CreatedDate on the first Original so
        // the ORDER BY CreatedDate DESC LIMIT 1 tiebreak cannot make this flaky
        // (both rows are otherwise inserted in the same test transaction).
        Test.setCreatedDate(older.Id, DateTime.now().addMinutes(-30));

        // Insert a newer Original after the first.
        ContentVersion cv2 = new ContentVersion();
        cv2.Title = 'Newer Original';
        cv2.PathOnClient = 'newer.pdf';
        cv2.VersionData = Blob.valueOf('newer bytes');
        cv2.FirstPublishLocationId = agr.Id;
        insert cv2;
        ContentVersion inserted2 = [SELECT Id FROM ContentVersion WHERE Id = :cv2.Id];
        Agreement_Document__c newer = new Agreement_Document__c();
        newer.Agreement__c = agr.Id;
        newer.Name = 'Newer Original';
        newer.Document_Type__c = 'Original';
        newer.Content_Version_ID__c = inserted2.Id;
        insert newer;

        Signer__c s1 = TestDataFactory.createSignerWithToken(agr.Id, 'multi@example.com');

        Test.startTest();
        Map<String, Object> data = DocumentVisibilityController.getVisibilityMatrix(agr.Id);
        Test.stopTest();

        List<Object> docs = (List<Object>) data.get('documents');
        Assert.areEqual(1, docs.size(),
            'Only the newest Original should be surfaced (DESC LIMIT 1)');
        Map<String, Object> dm = (Map<String, Object>) docs[0];
        Assert.areEqual(newer.Id, (Id) dm.get('id'),
            'Grid must resolve to the newest Original, not the replaced one');
    }

    @isTest
    static void getVisibilityMatrix_withAccessRecords_returnsCorrectVisibility() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Vis With Access');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'access@example.com');

        // Pre-existing access record — explicitly NO view permission
        Document_Signer_Access__c access = new Document_Signer_Access__c();
        access.Agreement_Document__c = doc.Id;
        access.Signer__c = signer.Id;
        access.Can_View__c = false;
        insert access;

        Test.startTest();
        Map<String, Object> data = DocumentVisibilityController.getVisibilityMatrix(agr.Id);
        Test.stopTest();

        List<Object> matrix = (List<Object>) data.get('matrix');
        Assert.areEqual(1, matrix.size());

        Map<String, Object> cell = (Map<String, Object>) matrix[0];
        Assert.areEqual(false, cell.get('canView'),
            'Existing access record with Can_View__c=false should be reflected');
    }

    @isTest
    static void getVisibilityMatrix_nonOriginalDocs_excluded() {
        // Only 'Original' docs should be in the matrix — 'Signed' / 'Stamped'
        // should not be visibility-controlled
        Agreement__c agr = TestDataFactory.createSentAgreement('Vis Originals Only');
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c = agr.Id;
        stamped.Name = 'Stamped Output';
        stamped.Document_Type__c = 'Stamped';
        stamped.Storage_Tier__c = 'Tier2';
        stamped.S3_Document_ID__c = 'stamped_id';
        insert stamped;

        Test.startTest();
        Map<String, Object> data = DocumentVisibilityController.getVisibilityMatrix(agr.Id);
        Test.stopTest();

        List<Object> docs = (List<Object>) data.get('documents');
        Assert.areEqual(1, docs.size(),
            'Only Original docs should be in visibility matrix');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  updateVisibility — insert + update branches
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void updateVisibility_newAccess_insertsRecord() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Update Insert');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'u@example.com');

        Test.startTest();
        DocumentVisibilityController.updateVisibility(doc.Id, signer.Id, false);
        Test.stopTest();

        List<Document_Signer_Access__c> created = [
            SELECT Can_View__c FROM Document_Signer_Access__c
            WHERE Agreement_Document__c = :doc.Id AND Signer__c = :signer.Id
        ];
        Assert.areEqual(1, created.size());
        Assert.areEqual(false, created[0].Can_View__c);
    }

    @isTest
    static void updateVisibility_existingAccess_updatesRecord() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Update Existing');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'u2@example.com');

        // Pre-create an access record with canView=true
        Document_Signer_Access__c existing = new Document_Signer_Access__c();
        existing.Agreement_Document__c = doc.Id;
        existing.Signer__c = signer.Id;
        existing.Can_View__c = true;
        insert existing;

        Test.startTest();
        // Toggle to false — should UPDATE not INSERT
        DocumentVisibilityController.updateVisibility(doc.Id, signer.Id, false);
        Test.stopTest();

        List<Document_Signer_Access__c> after = [
            SELECT Id, Can_View__c FROM Document_Signer_Access__c
            WHERE Agreement_Document__c = :doc.Id AND Signer__c = :signer.Id
        ];
        Assert.areEqual(1, after.size(),
            'Should still be only one record (update, not insert)');
        Assert.areEqual(existing.Id, after[0].Id,
            'Same record updated');
        Assert.areEqual(false, after[0].Can_View__c,
            'Can_View__c should be flipped to false');
    }

    @isTest
    static void updateVisibility_canViewTrue_setsTrue() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Update True');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'utrue@example.com');

        Test.startTest();
        DocumentVisibilityController.updateVisibility(doc.Id, signer.Id, true);
        Test.stopTest();

        Document_Signer_Access__c after = [
            SELECT Can_View__c FROM Document_Signer_Access__c
            WHERE Agreement_Document__c = :doc.Id AND Signer__c = :signer.Id LIMIT 1
        ];
        Assert.areEqual(true, after.Can_View__c);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  canSignerViewDocument — no record + record-exists branches
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void canSignerViewDocument_noAccessRecord_defaultsTrue() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Can View Default');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cv1@example.com');

        Test.startTest();
        Boolean canView = DocumentVisibilityController.canSignerViewDocument(doc.Id, signer.Id);
        Test.stopTest();

        Assert.areEqual(true, canView,
            'No access record → default to true (open visibility)');
    }

    @isTest
    static void canSignerViewDocument_accessRecordTrue_returnsTrue() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Can View True');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cv2@example.com');

        Document_Signer_Access__c access = new Document_Signer_Access__c();
        access.Agreement_Document__c = doc.Id;
        access.Signer__c = signer.Id;
        access.Can_View__c = true;
        insert access;

        Test.startTest();
        Boolean canView = DocumentVisibilityController.canSignerViewDocument(doc.Id, signer.Id);
        Test.stopTest();

        Assert.areEqual(true, canView);
    }

    @isTest
    static void canSignerViewDocument_accessRecordFalse_returnsFalse() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Can View False');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cv3@example.com');

        Document_Signer_Access__c access = new Document_Signer_Access__c();
        access.Agreement_Document__c = doc.Id;
        access.Signer__c = signer.Id;
        access.Can_View__c = false;
        insert access;

        Test.startTest();
        Boolean canView = DocumentVisibilityController.canSignerViewDocument(doc.Id, signer.Id);
        Test.stopTest();

        Assert.areEqual(false, canView,
            'Access record with Can_View__c=false should return false');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  initializeVisibility — fresh + idempotent branches
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void initializeVisibility_freshSetup_createsAllAccessRecords() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Init Fresh');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Signer__c s1 = TestDataFactory.createSignerWithToken(agr.Id, 'init1@example.com');
        Signer__c s2 = TestDataFactory.createSignerWithToken(agr.Id, 'init2@example.com');

        Test.startTest();
        DocumentVisibilityController.initializeVisibility(agr.Id);
        Test.stopTest();

        List<Document_Signer_Access__c> created = [
            SELECT Id, Can_View__c FROM Document_Signer_Access__c
            WHERE Agreement_Document__c = :doc.Id
        ];
        Assert.areEqual(2, created.size(),
            'Should create one access record per signer per doc');
        for (Document_Signer_Access__c a : created) {
            Assert.areEqual(true, a.Can_View__c,
                'Default Can_View__c should be true');
        }
    }

    @isTest
    static void initializeVisibility_existingRecords_skipped() {
        // If access records already exist for some doc/signer pairs,
        // initializeVisibility should skip them (no duplicates)
        Agreement__c agr = TestDataFactory.createSentAgreement('Init Idempotent');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c s1 = TestDataFactory.createSignerWithToken(agr.Id, 'idem1@example.com');
        Signer__c s2 = TestDataFactory.createSignerWithToken(agr.Id, 'idem2@example.com');

        // Pre-existing access record for s1
        Document_Signer_Access__c existing = new Document_Signer_Access__c();
        existing.Agreement_Document__c = doc.Id;
        existing.Signer__c = s1.Id;
        existing.Can_View__c = false;
        insert existing;

        Test.startTest();
        DocumentVisibilityController.initializeVisibility(agr.Id);
        Test.stopTest();

        List<Document_Signer_Access__c> after = [
            SELECT Id, Signer__c, Can_View__c FROM Document_Signer_Access__c
            WHERE Agreement_Document__c = :doc.Id
        ];
        Assert.areEqual(2, after.size(),
            'Should now have 2 access records — pre-existing + new for s2');

        // Pre-existing record should be untouched (Can_View__c still false)
        for (Document_Signer_Access__c a : after) {
            if (a.Signer__c == s1.Id) {
                Assert.areEqual(false, a.Can_View__c,
                    'Pre-existing record should not be modified');
            } else {
                Assert.areEqual(true, a.Can_View__c,
                    'New record for s2 should default to true');
            }
        }
    }

    @isTest
    static void initializeVisibility_noDocs_noOp() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Init No Docs');
        TestDataFactory.createSignerWithToken(agr.Id, 'nodocs@example.com');

        Test.startTest();
        DocumentVisibilityController.initializeVisibility(agr.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM Document_Signer_Access__c
            WHERE Signer__r.Agreement__c = :agr.Id
        ];
        Assert.areEqual(0, count,
            'No docs → no access records to create');
    }

    @isTest
    static void initializeVisibility_noSigners_noOp() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Init No Signers');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.startTest();
        DocumentVisibilityController.initializeVisibility(agr.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM Document_Signer_Access__c
            WHERE Agreement_Document__c = :doc.Id
        ];
        Assert.areEqual(0, count,
            'No signers → no access records to create');
    }
}