/**
 * CommentControllerTest — covers the agreement comment service.
 *
 * Methods:
 *   - addComment (from sender, from signer, with parent)
 *   - getComments (returns wrapped maps with formatting)
 *   - markAsRead / markAllAsRead (if present in full source)
 */
@isTest(SeeAllData=false)
private class CommentControllerTest {

    @isTest
    static void addComment_fromSender_insertsAndLogsAudit() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Comment Sender');

        Test.startTest();
        Id commentId = CommentController.addComment(
            agr.Id, 'Hello, please review.', 'Owner Name', 'owner@example.com', true, null
        );
        Test.stopTest();

        Assert.isNotNull(commentId);
        Agreement_Comment__c c = [
            SELECT Comment_Text__c, Author_Name__c, Author_Email__c,
                   Is_From_Sender__c, Is_Read__c
            FROM Agreement_Comment__c WHERE Id = :commentId
        ];
        Assert.areEqual('Hello, please review.', c.Comment_Text__c);
        Assert.areEqual(true, c.Is_From_Sender__c);
        Assert.areEqual(false, c.Is_Read__c);

        // Audit row should also exist
        Integer auditCount = [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :agr.Id AND Action__c = 'Comment Added'
        ];
        Assert.isTrue(auditCount >= 1, 'Audit event should be logged');
    }

    @isTest
    static void addComment_fromSigner_insertsCorrectly() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Comment Signer');

        Test.startTest();
        Id commentId = CommentController.addComment(
            agr.Id, 'Question about clause 3.', 'Alice', 'alice@example.com', false, null
        );
        Test.stopTest();

        Agreement_Comment__c c = [
            SELECT Is_From_Sender__c FROM Agreement_Comment__c WHERE Id = :commentId
        ];
        Assert.areEqual(false, c.Is_From_Sender__c);
    }

    @isTest
    static void addComment_withParent_setsParentReference() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Comment Reply');

        Id parentId = CommentController.addComment(
            agr.Id, 'Parent comment', 'Owner', 'o@example.com', true, null
        );

        Test.startTest();
        Id replyId = CommentController.addComment(
            agr.Id, 'Reply to parent', 'Alice', 'alice@example.com', false, parentId
        );
        Test.stopTest();

        Agreement_Comment__c reply = [
            SELECT Parent_Comment__c FROM Agreement_Comment__c WHERE Id = :replyId
        ];
        Assert.areEqual(parentId, reply.Parent_Comment__c);
    }

    @isTest
    static void getComments_returnsAllAsWrappedMaps() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Get Comments');
        CommentController.addComment(agr.Id, 'First', 'Owner', 'o@example.com', true, null);
        CommentController.addComment(agr.Id, 'Second', 'Alice', 'alice@example.com', false, null);

        Test.startTest();
        List<Map<String, Object>> got = CommentController.getComments(agr.Id);
        Test.stopTest();

        Assert.areEqual(2, got.size());
        // Each entry has the expected keys
        Map<String, Object> first = got[0];
        Assert.isTrue(first.containsKey('id'));
        Assert.isTrue(first.containsKey('text'));
        Assert.isTrue(first.containsKey('authorName'));
        Assert.isTrue(first.containsKey('createdDate'));
        Assert.isTrue(first.containsKey('initials'));
    }

    @isTest
    static void getComments_noComments_returnsEmptyList() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Empty Comments');

        Test.startTest();
        List<Map<String, Object>> got = CommentController.getComments(agr.Id);
        Test.stopTest();

        Assert.areEqual(0, got.size());
    }

    @isTest
    static void getComments_authorNameNull_returnsDefaultInitials() {
        // Comment with no author name → initials fallback '??'
        Agreement__c agr = TestDataFactory.createSentAgreement('No Author');
        Agreement_Comment__c c = new Agreement_Comment__c();
        c.Agreement__c = agr.Id;
        c.Comment_Text__c = 'Anon comment';
        c.Author_Name__c = null;
        c.Author_Email__c = 'a@b.com';
        c.Is_From_Sender__c = false;
        insert c;

        Test.startTest();
        List<Map<String, Object>> got = CommentController.getComments(agr.Id);
        Test.stopTest();

        Assert.areEqual(1, got.size());
        Assert.areEqual('??', got[0].get('initials'));
    }
}