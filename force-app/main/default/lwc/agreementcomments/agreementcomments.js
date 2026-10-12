import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getComments from '@salesforce/apex/CommentController.getComments';
import addComment from '@salesforce/apex/CommentController.addComment';
import markCommentsRead from '@salesforce/apex/CommentController.markCommentsRead';
import getUnreadCount from '@salesforce/apex/CommentController.getUnreadCount';
import Id from '@salesforce/user/Id';
import { stripNs } from 'c/nsUtils';

export default class AgreementComments extends LightningElement {
    @api recordId;
    @api signerEmail; // Pass this when used in signing page
    @api signerName;
    @api isGuest = false; // true when used in signing viewer

    @track isLoading = false;
    @track isExpanded = false;
    @track newComment = '';
    @track comments = [];
    @track unreadCount = 0;
    @track replyingToId = null;
    @track replyingToName = '';
    @track replyingToComment = false;

    currentUserId = Id;
    wiredCommentsResult;

    @wire(getComments, { agreementId: '$recordId' })
    wiredComments(result) {
        this.wiredCommentsResult = result;
        if (result.data) {
            this.processComments(stripNs(result.data));
        }
    }

    processComments(data) {
        this.comments = data.map(c => ({
            ...c,
            rowClass: c.isFromSender ? 'comment-row comment-row-sender' : 'comment-row comment-row-signer',
            avatarStyle: c.isFromSender
                ? 'background: linear-gradient(135deg, #0a1628, #1e3050);'
                : 'background: linear-gradient(135deg, #f59e0b, #d97706);'
        }));
    }

    connectedCallback() {
        this.loadUnreadCount();
    }

    async loadUnreadCount() {
        try {
            this.unreadCount = await getUnreadCount({ agreementId: this.recordId });
        } catch (e) { /* ignore */ }
    }

    get sendDisabled() {
        return !this.newComment || this.newComment.trim().length === 0;
    }

    toggleExpanded() {
        this.isExpanded = !this.isExpanded;
        if (this.isExpanded) {
            // Mark comments as read
            try { markCommentsRead({ agreementId: this.recordId }); } catch (e) { }
            this.unreadCount = 0;
        }
    }

    handleCommentChange(e) {
        this.newComment = e.target.value;
    }

    handleReplyTo(e) {
        const commentId = e.currentTarget.dataset.id;
        const comment = this.comments.find(c => c.id === commentId);
        if (comment) {
            this.replyingToId = commentId;
            this.replyingToName = comment.authorName;
            this.replyingToComment = true;
        }
    }

    cancelReply() {
        this.replyingToId = null;
        this.replyingToName = '';
        this.replyingToComment = false;
    }

    async handleSendComment() {
        if (!this.newComment || this.newComment.trim().length === 0) return;

        this.isLoading = true;
        try {
            let authorName = this.signerName || 'Agreement Owner';
            let authorEmail = this.signerEmail || '';
            let isFromSender = !this.isGuest;

            await addComment({
                agreementId: this.recordId,
                commentText: this.newComment.trim(),
                authorName: authorName,
                authorEmail: authorEmail,
                isFromSender: isFromSender,
                parentCommentId: this.replyingToId
            });

            this.newComment = '';
            this.cancelReply();
            // BUG-038 FIX: previously this called getComments() imperatively
            // which fetched fresh data but the @wire never knew about the
            // update — so any other consumers stayed stale and the wire's
            // internal cache held old data. Using refreshApex on the stored
            // wired result invalidates the cache and re-runs the wire,
            // which automatically calls processComments() through the wire
            // handler. Result: comment appears immediately, no manual refresh.
            await refreshApex(this.wiredCommentsResult);

            this.dispatchEvent(new ShowToastEvent({
                title: 'Sent',
                message: 'Comment added',
                variant: 'success'
            }));

        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: e.body?.message || 'Failed to add comment',
                variant: 'error'
            }));
        } finally {
            this.isLoading = false;
        }
    }
}