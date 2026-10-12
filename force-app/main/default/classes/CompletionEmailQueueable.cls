/**
 * Post-completion chain — runs AFTER the signing transaction commits, in two
 * phases (each its own transaction):
 *
 *   PHASE 1 (CERT): Regenerates the Signing Certificate now that ALL records
 *   are committed — signer statuses, Completed_Date__c, and the full audit
 *   trail. The certificate generated synchronously during signing reads
 *   PRE-COMMIT (stale) values; this regeneration replaces it with one that
 *   shows the LATEST values. generateAndAttachPDF renders first, validates
 *   the blob, and only then swaps the old certificate — so a failed render
 *   never loses the existing certificate. Then chains Phase 2.
 *
 *   PHASE 2 (EMAIL): Sends completion emails in a fresh transaction so the
 *   stamping/cert DML is committed first — otherwise the email's S3 fetches
 *   (HTTP callouts) would throw "uncommitted work pending" and the stamped
 *   PDF would be missing from the email.
 *
 * The single-argument constructor starts at Phase 1, so existing callers
 * (GuestSigningApi.runStampingAndEmailAsync) need no changes.
 */
public with sharing class CompletionEmailQueueable implements Queueable, Database.AllowsCallouts {

    private Id agreementId;
    private String phase;

    public CompletionEmailQueueable(Id agreementId) {
        this(agreementId, 'cert');
    }

    public CompletionEmailQueueable(Id agreementId, String phase) {
        this.agreementId = agreementId;
        this.phase = String.isBlank(phase) ? 'cert' : phase;
    }

    public void execute(QueueableContext ctx) {
        if (phase == 'cert') {
            // ── PHASE 1: regenerate certificate with committed (latest) data ──
            // The render itself runs in GuestSigningApi (the one `without
            // sharing` class), because this job executes as the Site Guest
            // User, who has no sharing access to the agreement's records.
            System.debug('CompletionChain[CERT]: regenerating certificate for ' + agreementId);
            GuestSigningApi.completionCertPhase(agreementId);
            System.debug('CompletionChain[CERT]: done');
            // Chain the email in its OWN transaction.
            try {
                System.enqueueJob(new CompletionEmailQueueable(agreementId, 'email'));
            } catch (Exception qe) {
                // Could not chain (queue limits) — send inline as last resort.
                System.debug(LoggingLevel.ERROR,
                    'CompletionChain[CERT]: chain failed, sending inline: ' + qe.getMessage());
                sendEmailSafe();
            }
            return;
        }

        // ── PHASE 2: completion emails ──
        sendEmailSafe();
    }

    private void sendEmailSafe() {
        // Cloud push + completion emails run in GuestSigningApi for the same
        // reason as the certificate phase: this job executes as the guest.
        System.debug('CompletionChain[EMAIL]: ===== Starting email send for ' + agreementId + ' =====');
        GuestSigningApi.completionEmailPhase(agreementId);
        System.debug('CompletionChain[EMAIL]: ===== Email send completed =====');
    }
}