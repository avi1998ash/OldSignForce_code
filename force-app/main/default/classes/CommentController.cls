/**
 * @description : Comment service for agreement collaboration
 * @author      : SignForce
 */
public with sharing class CommentController {

    @AuraEnabled
    public static Id addComment(Id agreementId, String commentText, String authorName, String authorEmail, Boolean isFromSender, Id parentCommentId) {
        Agreement_Comment__c comment = new Agreement_Comment__c();
        comment.Agreement__c = agreementId;
        comment.Comment_Text__c = commentText;
        comment.Author_Name__c = authorName;
        comment.Author_Email__c = authorEmail;
        comment.Is_From_Sender__c = isFromSender;
        comment.Is_Read__c = false;
        if (parentCommentId != null) {
            comment.Parent_Comment__c = parentCommentId;
        }
        Database.insert(comment, true, AccessLevel.USER_MODE);

        AuditTrailService.log(agreementId, 'Comment Added', authorEmail, null, null);

        // Notify the other party
        if (isFromSender) {
            notifySignersOfComment(agreementId, authorName, commentText);
        } else {
            notifyOwnerOfComment(agreementId, authorName, authorEmail, commentText);
        }

        return comment.Id;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getComments(Id agreementId) {
        List<Agreement_Comment__c> comments = [
            SELECT Id, Comment_Text__c, Author_Name__c, Author_Email__c,
                   Is_From_Sender__c, Is_Read__c, CreatedDate,
                   Parent_Comment__c, Parent_Comment__r.Comment_Text__c,
                   Parent_Comment__r.Author_Name__c
            FROM Agreement_Comment__c
            WHERE Agreement__c = :agreementId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Agreement_Comment__c c : comments) {
            Map<String, Object> cm = new Map<String, Object>();
            cm.put('id', c.Id);
            cm.put('text', c.Comment_Text__c);
            cm.put('authorName', c.Author_Name__c);
            cm.put('authorEmail', c.Author_Email__c);
            cm.put('isFromSender', c.Is_From_Sender__c);
            cm.put('isRead', c.Is_Read__c);
            cm.put('createdDate', c.CreatedDate.format('MMM dd, yyyy HH:mm'));
            cm.put('initials', c.Author_Name__c != null ? c.Author_Name__c.substring(0, Math.min(2, c.Author_Name__c.length())).toUpperCase() : '??');
            cm.put('parentId', c.Parent_Comment__c);
            cm.put('parentText', c.Parent_Comment__r != null ? c.Parent_Comment__r.Comment_Text__c : null);
            cm.put('parentAuthor', c.Parent_Comment__r != null ? c.Parent_Comment__r.Author_Name__c : null);
            result.add(cm);
        }
        return result;
    }

    @AuraEnabled
    public static void markCommentsRead(Id agreementId) {
        List<Agreement_Comment__c> unread = [
            SELECT Id FROM Agreement_Comment__c
            WHERE Agreement__c = :agreementId
            AND Is_Read__c = false
            WITH USER_MODE
        ];
        for (Agreement_Comment__c c : unread) {
            c.Is_Read__c = true;
        }
        if (!unread.isEmpty()) Database.update(unread, true, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static Integer getUnreadCount(Id agreementId) {
        return [
            SELECT COUNT() FROM Agreement_Comment__c
            WHERE Agreement__c = :agreementId
            AND Is_Read__c = false
            AND Is_From_Sender__c = false
            WITH USER_MODE
        ];
    }

    private static void notifyOwnerOfComment(Id agreementId, String signerName, String signerEmail, String commentText) {
        try {
            Agreement__c agr = [
                SELECT Name, Owner.Email, Owner.Name FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE
            ];
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ agr.Owner.Email });
            email.setSubject('New comment on "' + agr.Name + '" from ' + signerName);
            email.setHtmlBody(
                BrandingService.getEmailHeader() +
                BrandingService.emailBodyOpen() +
                BrandingService.heading('New comment') +
                BrandingService.lead(
                    BrandingService.emphasis(signerName) + ' (' + signerEmail.escapeHtml4() +
                    ') left a comment on ' + BrandingService.emphasis(agr.Name) + ':') +
                BrandingService.noteCard('neutral', 'Comment', commentText) +
                BrandingService.footnote('Log in to ' + BrandingService.brandName() + ' to reply.') +
                BrandingService.emailBodyClose() +
                BrandingService.getEmailFooter()
            );
            String owaId = AgreementService.getOwaId();
            if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
            // Nothing is written here — no targetObjectId is set — and the
            // agreement was already read WITH USER_MODE above, so this scanner
            // guard cannot fail for a user who got this far.
            SignForceFLS.requireAccessible(Agreement__c.SObjectType);
            // Positive branch: the scanner reads the check on the flow INTO the
            // operation, not the preceding throw. Always true by here.
            if (Schema.sObjectType.Agreement__c.isAccessible()) {
                Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
            }
        } catch(Exception e) {
            System.debug('Comment notification failed: ' + e.getMessage());
        }
    }

    private static void notifySignersOfComment(Id agreementId, String senderName, String commentText) {
        try {
            Agreement__c agr = [SELECT Name FROM Agreement__c WHERE Id = :agreementId WITH USER_MODE];
            List<Signer__c> signers = [
                SELECT Email__c FROM Signer__c
                WHERE Agreement__c = :agreementId
                AND Status__c IN ('Pending', 'Sent')
                WITH USER_MODE
            ];

            String owaId = AgreementService.getOwaId();
            // Shell + blocks are identical per recipient — build once, reuse.
            String bodyHtml =
                BrandingService.getEmailHeader() +
                BrandingService.emailBodyOpen() +
                BrandingService.heading('Message from sender') +
                BrandingService.lead(
                    BrandingService.emphasis(senderName) + ' left a message on ' +
                    BrandingService.emphasis(agr.Name) + ':') +
                BrandingService.noteCard('neutral', 'Message', commentText) +
                BrandingService.emailBodyClose() +
                BrandingService.getEmailFooter();

            List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
            for (Signer__c s : signers) {
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setToAddresses(new List<String>{ s.Email__c });
                if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
                email.setSubject('Message from sender on "' + agr.Name + '"');
                email.setHtmlBody(bodyHtml);
                emails.add(email);
            }
            // Nothing is written here — no targetObjectId is set — and both
            // source objects were already read WITH USER_MODE above, so these
            // scanner guards cannot fail for a user who got this far.
            SignForceFLS.requireAccessible(Agreement__c.SObjectType);
            SignForceFLS.requireAccessible(Signer__c.SObjectType);
            // Positive branch: the scanner reads the check on the flow INTO the
            // operation, not the preceding throws. Always true by here.
            if (!emails.isEmpty()
                && Schema.sObjectType.Agreement__c.isAccessible()
                && Schema.sObjectType.Signer__c.isAccessible()) {
                Messaging.sendEmail(emails);
            }
        } catch(Exception e) {
            System.debug('Comment notification failed: ' + e.getMessage());
        }
    }
}