/**
 * SignForceBulkSendTest — proves the DocuSign-style bulk send produces one
 * independent, sent agreement per recipient (each with its own copy of the
 * document, its own single signer, and the field layout).
 */
@IsTest
private class SignForceBulkSendTest {

    /** A master agreement with a Tier1 document, one signer and one field. */
    private static Id buildMaster() {
        Agreement__c master = new Agreement__c(
            Name = 'Master NDA',
            Agreement_Type__c = 'Contract',
            Signing_Order__c = 'Sequential',
            Status__c = 'Draft',
            Storage_Location__c = 'Salesforce'
        );
        insert master;

        ContentVersion cv = new ContentVersion(
            Title = 'Master NDA',
            PathOnClient = 'nda.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake pdf bytes'),
            Origin = 'H',
            FirstPublishLocationId = master.Id
        );
        insert cv;
        Id cvId = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;

        insert new Agreement_Document__c(
            Agreement__c = master.Id,
            Name = 'Master NDA',
            Content_Version_ID__c = cvId,
            Document_Type__c = 'Original',
            Storage_Tier__c = 'Tier1',
            File_Size_Bytes__c = 100
        );

        Signer__c ms = new Signer__c(
            Agreement__c = master.Id,
            Name = 'Template Signer',
            Email__c = 'template@example.com',
            Role__c = 'Signer',
            Signing_Order__c = 1,
            Status__c = 'Pending'
        );
        insert ms;

        insert new Signature_Field__c(
            Agreement__c = master.Id,
            Assigned_Signer__c = ms.Id,
            Field_Type__c = 'Signature',
            Field_Label__c = 'Sign here',
            Page_Number__c = 1,
            X_Position__c = 100,
            Y_Position__c = 200,
            Width__c = 150,
            Height__c = 40,
            Is_Required__c = true,
            Page_Width__c = 762
        );

        return master.Id;
    }

    @IsTest
    static void bulkSend_createsOneIndependentAgreementPerRecipient() {
        Id masterId = buildMaster();
        String recipients = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'name' => 'Alice', 'email' => 'alice@example.com' },
            new Map<String, Object>{ 'name' => 'Bob',   'email' => 'bob@example.com' }
        });

        Test.startTest();
        Map<String, Object> res = SignForceBulkSend.startBulkSend(masterId, recipients);
        Test.stopTest();   // runs the queueable

        Assert.areEqual(2, (Integer) res.get('total'), 'Two valid recipients');
        String batchId = (String) res.get('batchId');
        Assert.isNotNull(batchId, 'A batch id is returned');

        // Two NEW agreements (besides the master) were produced.
        List<Agreement__c> copies = [
            SELECT Id, Name, Status__c FROM Agreement__c WHERE Id != :masterId
        ];
        Assert.areEqual(2, copies.size(), 'One independent agreement per recipient');

        for (Agreement__c c : copies) {
            // Each copy was actually sent.
            Assert.areEqual('Sent', c.Status__c, 'Each copy is sent for signature');
            // Exactly one signer, and it is the recipient (not the master signer).
            List<Signer__c> sgs = [SELECT Email__c FROM Signer__c WHERE Agreement__c = :c.Id];
            Assert.areEqual(1, sgs.size(), 'Exactly one signer per copy');
            Assert.areNotEqual('template@example.com', sgs[0].Email__c, 'Signer is the recipient, not the master signer');
            // Its own document copy.
            Assert.areEqual(1, [SELECT COUNT() FROM Agreement_Document__c
                WHERE Agreement__c = :c.Id AND Document_Type__c = 'Original'],
                'Each copy has its own Original document');
            // Field layout copied and re-pointed to this signer.
            List<Signature_Field__c> flds = [SELECT Assigned_Signer__c FROM Signature_Field__c WHERE Agreement__c = :c.Id];
            Assert.areEqual(1, flds.size(), 'Field layout copied');
            Assert.areEqual(sgs[0].Id, flds[0].Assigned_Signer__c, 'Field assigned to the copy signer');
        }

        // Batch tracking reports the two agreements.
        Map<String, Object> status = SignForceBulkSend.getBulkStatus(masterId, batchId);
        Assert.areEqual(2, (Integer) status.get('total'), 'Manifest tracks both copies');
    }

    @IsTest
    static void bulkSend_deDupesAndValidates() {
        Id masterId = buildMaster();
        // Duplicate email + one blank/invalid — only one valid unique recipient.
        String recipients = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'name' => 'A', 'email' => 'dup@example.com' },
            new Map<String, Object>{ 'name' => 'A2', 'email' => 'dup@example.com' },
            new Map<String, Object>{ 'name' => 'X', 'email' => 'not-an-email' }
        });

        Test.startTest();
        Map<String, Object> res = SignForceBulkSend.startBulkSend(masterId, recipients);
        Test.stopTest();

        Assert.areEqual(1, (Integer) res.get('total'), 'Duplicate collapsed, invalid dropped');
        Assert.areEqual(1, [SELECT COUNT() FROM Agreement__c WHERE Id != :masterId], 'One copy created');
    }

    @IsTest
    static void bulkSend_rejectsMasterWithoutDocument() {
        Agreement__c bare = new Agreement__c(Name = 'No Doc', Status__c = 'Draft');
        insert bare;
        String recipients = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'name' => 'A', 'email' => 'a@example.com' }
        });
        Boolean threw = false;
        try {
            SignForceBulkSend.startBulkSend(bare.Id, recipients);
        } catch (Exception e) {
            threw = true;
        }
        Assert.isTrue(threw, 'A master with no document must be rejected');
    }
}