/**
 * AgreementServiceGuest — the guest-facing half of AgreementService.
 *
 * Holds the logic the public signing portal runs: token validation, marking a signer
 * signed, declines, the next-signer / signed-confirmation / completion emails and the
 * fresh S3 URL lookup. It is split out of AgreementService so that class can be
 * "with sharing" and carry no guest-only behaviour.
 *
 * SHARING: WITHOUT SHARING, on purpose. The only callers are the guest classes
 * (GuestSigningApi, AgreementControllerGuest), which are themselves without sharing:
 * the Site Guest User has no sharing access to Agreement__c / Signer__c, so these
 * queries and updates would find nothing under "with sharing". Access control is the
 * signing token, validated by SignForceAuthz / validateToken, exactly as before.
 *
 * Every method below is a verbatim copy of its AgreementService original (same
 * queries, DML, emails). The only edits are that calls to AgreementService's two
 * shared helpers, generateUUID and getOwaId, and the AgreementException type it throws are now qualified. Neither does DML or
 * reads sharing-governed data, so they stay in AgreementService for both audiences.
 * The originals remain in AgreementService, unchanged, until the dead-code removal
 * pass; nothing guest-facing calls them any more.
 */
public without sharing class AgreementServiceGuest {


    // Must match AgreementService.TOKEN_EXPIRY_HOURS (that constant is private there).
    private static final Integer TOKEN_EXPIRY_HOURS = 48;
    private static final Integer MAX_TOKEN_VIEWS = 50; // Rate limiting


    // Hybrid attachment thresholds
    // Salesforce single-email API caps total attachment size around 10MB. Stay under it.
    private static final Long MAX_TOTAL_ATTACHMENT_BYTES = 3145728L;  // 3 MB - dev-edition orgs convert to stubs above ~3MB combined
    private static final Long MAX_SINGLE_ATTACHMENT_BYTES = 3145728L; // 3 MB single

    // ════════════════════════════════════════════════
    //  TOKEN VALIDATION
    // ════════════════════════════════════════════════

    /**
* Validates a signing token - checks expiry, rate limiting, and status
*/
    public static Map<String, Object> validateToken(String token) {
        Map<String, Object> response = new Map<String, Object>();
        
        if (String.isBlank(token) || token.length() < 10) {
            response.put('error', 'Invalid signing link.');
            return response;
        }
        
        List<Signer__c> signers = [
            SELECT Id, Name, Email__c, Agreement__c, Status__c,
            Token_Created_Date__c, Token_Expired__c, Token_View_Count__c,
            OTP_Verified__c
            FROM Signer__c
            WHERE Access_Token__c = :token
            LIMIT 1
        ];
        
        if (signers.isEmpty()) {
            response.put('error', 'Invalid or expired signing link.');
            return response;
        }
        
        Signer__c signer = signers[0];
        
        // Check if token was manually expired
        if (signer.Token_Expired__c == true) {
            response.put('error', 'This signing link has been revoked.');
            return response;
        }
        
        // Check if already signed
        if (signer.Status__c == 'Signed') {
            response.put('error', 'You have already signed this document.');
            return response;
        }
        
        // Check if declined
        if (signer.Status__c == 'Declined') {
            response.put('error', 'This document has been declined.');
            return response;
        }
        
        // Check token expiry (48 hours)
        if (signer.Token_Created_Date__c != null) {
            DateTime expiryTime = signer.Token_Created_Date__c.addHours(TOKEN_EXPIRY_HOURS);
            if (DateTime.now() > expiryTime) {
                response.put('error', 'This signing link has expired. Please request a new one from the sender.');
                return response;
            }
        }
        
        // Rate limiting - max views
        Decimal viewCount = signer.Token_View_Count__c != null ? signer.Token_View_Count__c : 0;
        if (viewCount >= MAX_TOKEN_VIEWS) {
            response.put('error', 'This signing link has been accessed too many times. Please contact the sender.');
            return response;
        }
        
        // Check agreement status
        Agreement__c agr = [
            SELECT Id, Name, Status__c, Envelope_ID__c, Expiry_Date__c
            FROM Agreement__c WHERE Id = :signer.Agreement__c LIMIT 1
        ];
        
        if (agr.Status__c == 'Voided') {
            response.put('error', 'This agreement has been voided by the sender.');
            return response;
        }
        
        if (agr.Status__c == 'Completed') {
            response.put('error', 'This agreement has already been completed.');
            return response;
        }
        
        // Check agreement expiry date
        if (agr.Expiry_Date__c != null && DateTime.now() > agr.Expiry_Date__c) {
            response.put('error', 'This agreement has expired.');
            // Auto-expire the agreement
            agr.Status__c = 'Voided';
            agr.Void_Reason__c = 'Expired';
            agr.Voided_Date__c = DateTime.now();
            update agr;
            AuditTrailServiceGuest.log(agr.Id, 'Agreement Expired', 'system@signforce.com', null, null);
            return response;
        }
        
        // Increment view count
        signer.Token_View_Count__c = viewCount + 1;
        update signer;
        
        // Log the view
        AuditTrailServiceGuest.log(agr.Id, 'Document Viewed', signer.Email__c, null, null);
        
        response.put('signerId', signer.Id);
        response.put('signerEmail', signer.Email__c);
        // Signer's full name (Signer__c.Name) so the signing viewer can
        // auto-populate the "Full Name" on the signature adopt sheet instead
        // of making the signer type it. May be blank if the signer was created
        // without a name; the LWC guards against that and simply no-ops.
        response.put('signerName', signer.Name);
        response.put('agreementName', agr.Name);
        response.put('agreementId', agr.Id);
        response.put('envelopeId', agr.Envelope_ID__c);
        // Whether this signer already passed the emailed one-time-code gate —
        // the signing viewer skips the OTP screen when true.
        response.put('otpVerified', signer.OTP_Verified__c == true);
        return response;
    }

    // ════════════════════════════════════════════════
    //  SIGNING / DECLINING
    // ════════════════════════════════════════════════

    // Backward-compatible 3-arg: same IP for the signer record and the audit event.
    public static void markSigned(Id signerId, String ipAddress, String userAgent) {
        markSigned(signerId, ipAddress, ipAddress, userAgent);
    }

    // signerIp → Signer record's "Using IP Address" (we store the IPv6 here);
    // auditIp  → the "Document Signed" audit-trail event (we store the IPv4 here).
    public static void markSigned(Id signerId, String signerIp, String auditIp, String userAgent) {
        Signer__c signer = [
            SELECT Id, Agreement__c, Signing_Order__c, Status__c, Role__c, Email__c, Access_Token__c
            FROM Signer__c WHERE Id = :signerId
        ];
        System.debug(LoggingLevel.INFO,
            '[SignForce IP] markSigned signerIp(v6)=[' + signerIp + '] auditIp(v4)=[' + auditIp + ']');

        // Already signed → nothing to do. Without this a second call (a
        // double-clicked Complete button, a retried request) overwrites
        // Signed_Date__c and issues a fresh Signature_Certificate_ID__c —
        // destroying the audit record of the original signature — and sends the
        // confirmation email all over again.
        if (signer.Status__c == 'Signed') return;

        signer.Status__c = 'Signed';
        signer.Signed_Date__c = DateTime.now();
        signer.Signature_Certificate_ID__c = AgreementService.generateUUID();
        signer.Signing_IP_Address__c = signerIp;
        signer.Signing_User_Agent__c = userAgent;
        update signer;
        AuditTrailServiceGuest.log(signer.Agreement__c, 'Document Signed', signer.Email__c, auditIp, userAgent);
        checkAgreementCompletion(signer.Agreement__c);

        // "You have signed successfully" to the person who just signed — every
        // signer, including the last. It lives here rather than in the callers so
        // that guest signing and in-org signing behave identically; there is more
        // than one entry point and they used to disagree.
        //
        // Runs AFTER checkAgreementCompletion so the message knows whether anyone
        // is still outstanding. Carries no attachment and makes no callout, so it
        // is safe in this already-DML'd transaction.
        //
        // Skipped for a single-signer agreement: that person receives exactly one
        // email, the completion one, which confirms their signature AND carries the
        // documents.
        // Role__c may be null — sendForSignature invites everyone who is not a CC,
        // so a blank-role recipient really can hold a signing link. SOQL never
        // matches NULL with = or IN, so these predicates must say so explicitly or
        // that person is invisible to every count here.
        Integer signerCount = [
            SELECT COUNT() FROM Signer__c
            WHERE Agreement__c = :signer.Agreement__c
            AND (Role__c = 'Signer' OR Role__c = null)
        ];
        // Only actual signers are told "you have signed" — an Approver reaching
        // this method has approved, not signed.
        Boolean isSignerRole = String.isBlank(signer.Role__c) || signer.Role__c == 'Signer';

        // The LAST signer is skipped: completing the agreement immediately sends
        // them the "all parties have signed" email, which already confirms their
        // signature and carries the documents. A confirmation on top of it would be
        // two emails for one action, seconds apart.
        Boolean justCompleted = false;
        for (Agreement__c a : [
            SELECT Status__c FROM Agreement__c WHERE Id = :signer.Agreement__c LIMIT 1
        ]) {
            justCompleted = (a.Status__c == 'Completed');
        }

        if (signerCount > 1 && isSignerRole && !justCompleted) {
            try {
                sendSignedConfirmationEmail(signer.Agreement__c, signer.Id);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'Signed-confirmation email failed (non-fatal): ' + e.getMessage());
            }
        }
    }

    public static void declineAgreement(Id signerId, String reason, String ipAddress) {
        Signer__c signer = [
            SELECT Id, Agreement__c, Email__c, Name
            FROM Signer__c WHERE Id = :signerId
        ];
        signer.Status__c = 'Declined';
        signer.Decline_Reason__c = reason;
        update signer;
        
        Agreement__c agr = [
            SELECT Id, Name, Status__c, OwnerId, Owner.Email, Owner.Name
            FROM Agreement__c WHERE Id = :signer.Agreement__c
        ];
        agr.Status__c = 'Declined';
        update agr;
        
        AuditTrailServiceGuest.log(signer.Agreement__c, 'Declined', signer.Email__c, ipAddress, reason);
        
        // Send decline notification to owner
        sendDeclineNotification(agr, signer, reason);
    }

    public static void declineAgreementGuest(Id signerId, String reason) {
        declineAgreement(signerId, reason, null);
    }

    /**
* Notify the agreement owner when a signer declines
*/
    private static void sendDeclineNotification(Agreement__c agr, Signer__c signer, String reason) {
        try {
            String headerHtml = getEmailHeader();
            String footerHtml = getEmailFooter();
            String declinedAt = DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());
            
            String body =
                headerHtml +
                BrandingServiceGuest.emailBodyOpen() +
                BrandingServiceGuest.pill('danger', 'DECLINED') +
                BrandingServiceGuest.heading('Document was declined') +
                BrandingServiceGuest.lead(
                    BrandingServiceGuest.emphasis(signer.Email__c) + ' has declined to sign ' +
                    BrandingServiceGuest.emphasis(agr.Name) + '.') +
                BrandingServiceGuest.metaCard(
                    new List<String>{ 'Declined by', 'When' },
                    new List<String>{ signer.Email__c, declinedAt }) +
                (String.isNotBlank(reason) ? BrandingServiceGuest.noteCard('danger', 'Reason given', reason) : '') +
                BrandingServiceGuest.footnote('The agreement is no longer active. No further signatures will be requested.') +
                BrandingServiceGuest.emailBodyClose() +
                footerHtml;
            
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ agr.Owner.Email });
            email.setSubject('Declined: "' + agr.Name + '" was declined by ' + signer.Email__c);
            String owaId = AgreementService.getOwaId();
            if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
            email.setHtmlBody(body);
            // CRUD: addressed from the Agreement__c owner, bodied from the
            // Signer__c row - both read above, both readable by guest.
            if (Schema.sObjectType.Agreement__c.isAccessible()
                && Schema.sObjectType.Signer__c.isAccessible()) {
                Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
            }
        } catch(Exception e) {
            System.debug('Decline notification failed: ' + e.getMessage());
        }
    }

    // ════════════════════════════════════════════════
    //  COMPLETION CHECK AND EMAILS
    // ════════════════════════════════════════════════

    private static void checkAgreementCompletion(Id agreementId) {
        List<Signer__c> signers = [
            SELECT Id, Status__c, Role__c, Signing_Order__c, Email__c, Access_Token__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            AND (Role__c = 'Signer' OR Role__c = null)
            ORDER BY Signing_Order__c ASC NULLS LAST
        ];
        Agreement__c agr = [
            SELECT Id, Signing_Order__c, Status__c, Name,
            Message_to_Signers__c, OwnerId, Owner.Email, Owner.Name
            FROM Agreement__c WHERE Id = :agreementId
        ];
        Boolean allSigned = true;
        // Sequential advance, group-aware: everyone at the lowest unsigned order
        // is in play together. Only 'Pending' members get an email here — group
        // members invited at send time are already 'Sent', so one member signing
        // does not spam the rest of the group with duplicate invitations.
        Boolean groupFound = false;
        Decimal activeOrder = null;
        for (Signer__c s : signers) {
            if (s.Status__c == 'Signed') continue;
            allSigned = false;
            if (agr.Signing_Order__c != 'Sequential') break;
            if (!groupFound) { groupFound = true; activeOrder = s.Signing_Order__c; }
            Boolean sameGroup = (s.Signing_Order__c == activeOrder)
                || (s.Signing_Order__c == null && activeOrder == null);
            if (sameGroup && s.Status__c == 'Pending') {
                sendSignerEmail(s, agr);
            }
        }
        if (allSigned) {
            agr.Status__c = 'Completed';
            agr.Completed_Date__c = DateTime.now();
            update agr;

            // BUG-061: CC recipients (Role__c='CC') are created 'Pending' and were
            // never advanced, so they showed "Pending" forever after completion.
            // Now that all SIGNERS have signed, move any still-open CC rows to a
            // terminal status. Signer__c.Status__c is a RESTRICTED picklist whose
            // values are: Pending, Sent, Viewed, Signed, Declined, Voided — there
            // is no 'Completed'/'Notified' value, so we reuse the same terminal
            // value signers receive on completion ('Signed'). The allSigned gate
            // above filters Role__c='Signer' only, so CCs never block completion
            // and this status change cannot affect completion semantics.
            List<Signer__c> ccRows = [
                SELECT Id, Status__c
                FROM Signer__c
                WHERE Agreement__c = :agreementId
                AND Role__c = 'CC'
                AND Status__c != 'Signed'
                AND Status__c != 'Declined'
                AND Status__c != 'Voided'
            ];
            if (!ccRows.isEmpty()) {
                for (Signer__c cc : ccRows) {
                    cc.Status__c = 'Signed';
                }
                update ccRows;
            }

            // Completion is reached automatically when the last signer signs
            // (often a guest signing session), so there is no initiating
            // Salesforce user — use a safe system literal rather than the
            // (guest) running user's email.
            AuditTrailServiceGuest.log(agreementId, 'Agreement Completed', 'system@signforce.com', null, null);
        }
    }

    public static void sendCompletionEmailsPublic(Id agreementId) {
        Agreement__c agr = [
            SELECT Id, Name, Status__c, Signing_Order__c,
            Message_to_Signers__c, OwnerId, Owner.Email, Owner.Name
            FROM Agreement__c WHERE Id = :agreementId
        ];
        // BUG-030 FIX: completion notification should reach ALL parties on the
        // agreement (Signer, Approver, CC). Previously only Role__c='Signer'
        // got the email so Approvers and CCs never knew the deal closed.
        // Note: the role filter in checkAgreementCompletion() is intentionally
        // left as 'Signer'-only because completion semantics require all
        // signers to sign; approvers/CCs aren't expected to sign anything.
        List<Signer__c> signers = [
            SELECT Id, Status__c, Role__c, Signing_Order__c, Email__c, Access_Token__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            AND (Role__c IN ('Signer', 'Approver', 'CC') OR Role__c = null)
            ORDER BY Signing_Order__c ASC NULLS LAST
        ];
        sendCompletionEmails(agr, signers);
    }

    /**
     * "You have signed successfully" — sent to a signer immediately after THEY
     * sign, for every signer including the last one.
     *
     * Carries NO attachment by design. Documents travel only with the final
     * completion email, once every party has signed; sending a part-signed PDF at
     * each step puts an incomplete copy of a legal document into circulation and
     * leaves recipients unsure which version is authoritative.
     *
     * Sent only while signatures are still outstanding. The person who signs LAST
     * does not get one — completing the agreement sends them the "all parties have
     * signed" email, which confirms their signature and carries the documents in a
     * single message. A single-signer agreement is the same case: one email only.
     */
    public static void sendSignedConfirmationEmail(Id agreementId, Id signerId) {
        Agreement__c agr = [SELECT Id, Name FROM Agreement__c WHERE Id = :agreementId];
        Signer__c signer = [SELECT Id, Name, Email__c FROM Signer__c WHERE Id = :signerId];
        if (String.isBlank(signer.Email__c)) return;

        String nextStep = 'The next signer has been notified. '
            + 'You will receive the completed document once everyone has signed.';

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ signer.Email__c });
        mail.setSubject('You have signed "' + agr.Name + '"');
        mail.setHtmlBody(
            getEmailHeader()
            + BrandingServiceGuest.emailBodyOpen()
            + BrandingServiceGuest.pill('success', 'SIGNED')
            + BrandingServiceGuest.heading('You have signed successfully')
            + BrandingServiceGuest.lead('Hi ' + BrandingServiceGuest.emphasis(signer.Name)
                + ', you have successfully signed ' + BrandingServiceGuest.emphasis(agr.Name) + '.')
            + BrandingServiceGuest.paragraph(nextStep)
            + BrandingServiceGuest.footnote('Sent via ' + BrandingServiceGuest.brandName())
            + BrandingServiceGuest.emailBodyClose()
            + getEmailFooter()
        );
        String owaId = AgreementService.getOwaId();
        if (String.isNotBlank(owaId)) mail.setOrgWideEmailAddressId(owaId);

        // CRUD: built from the Agreement__c and Signer__c rows read above.
        // Guest holds read on both, so the branch is always taken.
        if (Schema.sObjectType.Signer__c.isAccessible()
            && Schema.sObjectType.Agreement__c.isAccessible()) {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        }
        AuditTrailServiceGuest.log(agreementId, 'Signed Confirmation Emailed', signer.Email__c, null, null);
    }

    private static void sendCompletionEmails(Agreement__c agr, List<Signer__c> signers) {
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        
        String headerHtml = getEmailHeader();
        String footerHtml = getEmailFooter();
        
        String completedOn = DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());
        
        // De-dupe recipients: a person who is BOTH the owner and a signer
        // (e.g. self-sign / sender signs their own doc) must not receive two
        // completion emails — the duplicate "Completed:" pair reported by users.
        Set<String> signerEmailSet = new Set<String>();
        Integer signerRoleCount = 0;
        for (Signer__c sig : signers) {
            if (String.isNotBlank(sig.Email__c)) signerEmailSet.add(sig.Email__c.trim().toLowerCase());
            // Same population checkAgreementCompletion gates on — including the
            // blank role it also accepts — so soleSigner is computed over exactly
            // the people who had to sign and were sent a confirmation.
            if (String.isBlank(sig.Role__c) || sig.Role__c == 'Signer') signerRoleCount++;
        }
        // A single-signer agreement produces exactly ONE email in total: the one
        // below, to that signer, carrying the documents. There is no round of
        // "you have signed" confirmations to summarise and nobody else is waiting,
        // so an "all parties have signed" announcement to the sender would just be
        // a second copy of news they can already see on the record.
        Boolean soleSigner = (signerRoleCount <= 1);

        Set<String> sentTo = new Set<String>();
        String owaId = AgreementService.getOwaId();
        String ownerAddr = (agr.Owner != null) ? agr.Owner.Email : null;
        Boolean ownerIsSigner = String.isNotBlank(ownerAddr)
            && signerEmailSet.contains(ownerAddr.trim().toLowerCase());

        // ── Owner: "all parties signed" — skipped when the owner is also a signer
        //    (they get the per-signer email with the same Stamped + Certificate
        //    attachments), and skipped entirely for a sole-signer agreement. ──
        if (String.isNotBlank(ownerAddr) && !ownerIsSigner && !soleSigner) {
        List<String> signerEmails = new List<String>();
        for (Signer__c sig : signers) {
            if (String.isNotBlank(sig.Email__c)) signerEmails.add(sig.Email__c);
        }
        String ownerBody =
            headerHtml +
            BrandingServiceGuest.emailBodyOpen() +
            BrandingServiceGuest.pill('success', 'COMPLETED') +
            BrandingServiceGuest.heading('All parties have signed') +
            BrandingServiceGuest.lead(
                BrandingServiceGuest.emphasis(agr.Name) +
                ' has been signed by everyone. The signed document and audit certificate are included with this email.') +
            BrandingServiceGuest.metaCard(
                new List<String>{ 'Completed on', 'Signers' },
                new List<String>{ completedOn, signers.size() + ' parties' }) +
            BrandingServiceGuest.panelCard('Signed by', BrandingServiceGuest.bulletList('successDot', signerEmails)) +
            BrandingServiceGuest.footnote('Keep this email for your records. The signed PDF is legally binding.') +
            BrandingServiceGuest.emailBodyClose() +
            footerHtml;
        
        Messaging.SingleEmailMessage ownerEmail = new Messaging.SingleEmailMessage();
        ownerEmail.setToAddresses(new List<String>{ ownerAddr });
        ownerEmail.setSubject('Completed: "' + agr.Name + '" has been signed by all parties');
        if (String.isNotBlank(owaId)) ownerEmail.setOrgWideEmailAddressId(owaId);
        ownerEmail.setHtmlBody(ownerBody);
        emails.add(ownerEmail);
        }
        
        // ── Per-signer: role-aware completion notification ────────────
        // BUG-030 FIX: Approvers and CCs now receive completion emails too,
        // but the body/subject must NOT say "You have signed" for them.
        for (Signer__c s : signers) {
            // Skip blank addresses and anyone already emailed (owner overlap or
            // the same person listed as a signer more than once).
            if (String.isBlank(s.Email__c)) continue;
            String sKey = s.Email__c.trim().toLowerCase();
            if (sentTo.contains(sKey)) continue;
            sentTo.add(sKey);
            String role = String.isBlank(s.Role__c) ? 'Signer' : s.Role__c;
            Boolean isSigner = (role == 'Signer');
            Boolean isApprover = (role == 'Approver');
            // Anything else (CC, etc.) → treated as informational copy
            
            String pillLabel;
            String headlineText;
            String bodyText;
            String subject;
            String dateLabel;
            if (isSigner && soleSigner) {
                // The only email this person receives: it confirms their signature
                // and carries the documents in one go.
                pillLabel    = 'SIGNED';
                headlineText = 'You have signed successfully';
                bodyText     = 'Thank you for signing ' + BrandingServiceGuest.emphasis(agr.Name)
                    + '. A copy of the fully executed document is attached for your records.';
                subject      = 'Completed: You have signed "' + agr.Name + '"';
                dateLabel    = 'Signed on';
            } else if (isSigner) {
                // Every signer already received a "you have signed successfully"
                // confirmation the moment they signed, so this email announces that
                // EVERYONE is done and delivers the documents.
                pillLabel    = 'COMPLETED';
                headlineText = 'All parties have signed';
                bodyText     = BrandingServiceGuest.emphasis(agr.Name)
                    + ' has been signed by everyone. The signed document and audit certificate are attached for your records.';
                subject      = 'Completed: "' + agr.Name + '" has been signed by all parties';
                dateLabel    = 'Completed on';
            } else if (isApprover) {
                pillLabel    = 'COMPLETED';
                headlineText = 'Agreement completed';
                bodyText     = 'The agreement ' + BrandingServiceGuest.emphasis(agr.Name)
                    + ' has been fully executed by all signers. As an approver, a copy of the signed document is attached for your records.';
                subject      = 'Completed: "' + agr.Name + '" has been signed';
                dateLabel    = 'Completed on';
            } else {
                // CC or any other informational role
                pillLabel    = 'COMPLETED';
                headlineText = 'Agreement completed';
                bodyText     = 'You are copied on the agreement ' + BrandingServiceGuest.emphasis(agr.Name)
                    + ', which has been fully executed by all signers. A copy of the signed document is attached for your reference.';
                subject      = 'Completed (cc): "' + agr.Name + '"';
                dateLabel    = 'Completed on';
            }
            
            String signerBody =
                headerHtml +
                BrandingServiceGuest.emailBodyOpen() +
                BrandingServiceGuest.pill('success', pillLabel) +
                BrandingServiceGuest.heading(headlineText) +
                BrandingServiceGuest.lead(bodyText) +
                BrandingServiceGuest.metaCard(
                    new List<String>{ dateLabel },
                    new List<String>{ completedOn }) +
                BrandingServiceGuest.footnote('Keep this email for your records. The signed PDF is legally binding.') +
                BrandingServiceGuest.emailBodyClose() +
                // The download-links row is injected at the <!--SF_BODY_END--> sentinel
                // that getEmailFooter() emits, so the injected <tr> lands inside the
                // outer table (Gmail drops <tr>s that fall outside </table>).
                footerHtml;
            
            Messaging.SingleEmailMessage signerEmail = new Messaging.SingleEmailMessage();
            signerEmail.setToAddresses(new List<String>{ s.Email__c });
            signerEmail.setSubject(subject);
            if (String.isNotBlank(owaId)) signerEmail.setOrgWideEmailAddressId(owaId);
            signerEmail.setHtmlBody(signerBody);
            emails.add(signerEmail);
        }
        
        if (!emails.isEmpty()) {
            
            // ─── HYBRID ATTACHMENT STRATEGY ─────────────────────────────────
            // Salesforce single-email API caps total attachment size at ~10MB.
            // Above that, Salesforce silently converts attachments to "click to
            // download" HTML stubs — a poor user experience.
            //
            // Strategy:
            //   1. Try to inline-attach Stamped (preferred) + Cert
            //   2. Track running total; if next attachment would exceed 9MB cap,
            //      switch it to a presigned S3 download link in the email body
            //   3. Original is NOT attached when Stamped exists (redundant — the
            //      stamped PDF contains everything from the original plus signatures)
            //
            // Attachment metadata: we collect (filename, blob, optional fallback URL)
            // pairs first, then decide inline-vs-link based on cumulative size.
            
            List<Messaging.EmailFileAttachment> inlineAttachments = new List<Messaging.EmailFileAttachment>();
            List<Map<String, String>> downloadLinks = new List<Map<String, String>>();
            Long runningTotal = 0L;
            
            // ── 1. Stamped Signed Document (preferred primary attachment) ──
            // Pick the latest valid Stamped record (has S3 or CV content).
            // If duplicate Stamped records exist due to Guest User not having
            // delete permission, this picks the most recent valid one.
            List<Agreement_Document__c> stampedDocs = [
                SELECT Id, Name, Content_Version_ID__c, S3_Document_ID__c, S3_Preview_URL__c, Storage_Tier__c, File_Size_Bytes__c,
                    Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agr.Id
                AND Document_Type__c = 'Stamped'
                AND (S3_Document_ID__c != null OR Content_Version_ID__c != null
                     OR (Storage_Type__c = 'Cloud' AND Cloud_File_Id__c != null))
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            
            if (!stampedDocs.isEmpty()) {
                System.debug('Email: Found Stamped record: S3=' + stampedDocs[0].S3_Document_ID__c 
                             + ', CV=' + stampedDocs[0].Content_Version_ID__c);
            } else {
                System.debug('Email: No valid Stamped record found, will fallback to Original');
            }
            Boolean stampedAttached = false;
            if (!stampedDocs.isEmpty()) {
                Agreement_Document__c d = stampedDocs[0];
                String title = sanitizeFileName(
                    String.isNotBlank(d.Name) ? d.Name : (agr.Name + ' - Signed Document')
                );
                AttachmentResult ar = tryAttachOrLink(d, title, runningTotal);
                if (ar != null) {
                    if (ar.attachment != null) {
                        inlineAttachments.add(ar.attachment);
                        runningTotal += ar.size;
                        System.debug('Email: inline-attached Stamped (' + ar.size + ' bytes)');
                    } else if (String.isNotBlank(ar.downloadUrl)) {
                        downloadLinks.add(new Map<String, String>{
                            'label' => title + ' (Signed Document)',
                                'url'   => ar.downloadUrl
                                });
                        System.debug('Email: Stamped too large — added download link');
                    }
                    stampedAttached = (ar.attachment != null) || String.isNotBlank(ar.downloadUrl);
                }
            }
            
            // ── Fallback: Original if Stamped genuinely missing ──
            if (!stampedAttached) {
                List<Agreement_Document__c> origDocs = [
                    SELECT Id, Name, Content_Version_ID__c, S3_Document_ID__c, S3_Preview_URL__c, Storage_Tier__c, File_Size_Bytes__c,
                        Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
                    FROM Agreement_Document__c
                    WHERE Agreement__c = :agr.Id
                    AND Document_Type__c = 'Original'
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
                if (!origDocs.isEmpty()) {
                    Agreement_Document__c d = origDocs[0];
                    String title = sanitizeFileName(
                        String.isNotBlank(d.Name) ? d.Name : agr.Name
                    );
                    AttachmentResult ar = tryAttachOrLink(d, title, runningTotal);
                    if (ar != null) {
                        if (ar.attachment != null) {
                            inlineAttachments.add(ar.attachment);
                            runningTotal += ar.size;
                            System.debug('Email: inline-attached Original fallback');
                        } else if (String.isNotBlank(ar.downloadUrl)) {
                            downloadLinks.add(new Map<String, String>{
                                'label' => title,
                                    'url'   => ar.downloadUrl
                                    });
                        }
                    }
                }
            }
            
            // ── 2. Signing Certificate ──
            List<Agreement_Document__c> certDocs = [
                SELECT Id, Name, Content_Version_ID__c, S3_Document_ID__c, S3_Preview_URL__c, Storage_Tier__c, File_Size_Bytes__c,
                    Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agr.Id
                AND Document_Type__c = 'Signed'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!certDocs.isEmpty()) {
                Agreement_Document__c d = certDocs[0];
                String title = sanitizeFileName(
                    String.isNotBlank(d.Name) && !d.Name.startsWith('a0')
                    ? d.Name
                    : (agr.Name + ' - Signing Certificate')
                );
                AttachmentResult ar = tryAttachOrLink(d, title, runningTotal);
                if (ar != null) {
                    if (ar.attachment != null) {
                        inlineAttachments.add(ar.attachment);
                        runningTotal += ar.size;
                        System.debug('Email: inline-attached Certificate');
                    } else if (String.isNotBlank(ar.downloadUrl)) {
                        downloadLinks.add(new Map<String, String>{
                            'label' => title + ' (Audit Certificate)',
                                'url'   => ar.downloadUrl
                                });
                    }
                }
            }
            
            // ── Inject download-links section into HTML body if any ──
            if (!downloadLinks.isEmpty()) {
                String linksHtml = buildDownloadLinksHtml(downloadLinks);
                for (Messaging.SingleEmailMessage email : emails) {
                    String body = email.getHtmlBody();
                    if (body != null) {
                        // Insert at SF_BODY_END sentinel (preferred), else just before </body>.
                        Integer idx = body.indexOf('<!--SF_BODY_END-->');
                        if (idx < 0) idx = body.toLowerCase().indexOf('</body>');
                        if (idx > 0) {
                            email.setHtmlBody(body.substring(0, idx) + linksHtml + body.substring(idx));
                        } else {
                            email.setHtmlBody(body + linksHtml);
                        }
                    } else {
                        email.setHtmlBody(linksHtml);
                    }
                }
            }
            
            if (!inlineAttachments.isEmpty()) {
                for (Messaging.SingleEmailMessage email : emails) {
                    email.setFileAttachments(inlineAttachments);
                }
            }
            
            System.debug('SignForce Email: sending ' + emails.size()
                         + ' emails, ' + inlineAttachments.size() + ' inline + '
                         + downloadLinks.size() + ' links, total inline bytes ' + runningTotal);

            // Sent per recipient, not all-or-none. Messaging.sendEmail defaults to
            // all-or-none, so a SINGLE unusable address rejects the entire batch
            // and nobody learns the agreement completed. A CC address is the most
            // likely offender: unlike a signer's, it is typed once and never proved
            // by anyone opening a signing link, so a typo goes unnoticed until the
            // one email that would have used it. Every caller of this method wraps
            // it in a catch that only writes a debug line, so that rejection left
            // no trace anywhere an admin could see it — hence the audit entry
            // below, recorded against the address that actually failed.
            // CRUD: the recipients come from the Agreement__c owner and the
            // Signer__c rows read above; their read access gates the send. Both
            // are readable by guest, so the branch is always taken and the
            // per-recipient reporting below is unchanged.
            List<Messaging.SendEmailResult> results = new List<Messaging.SendEmailResult>();
            if (Schema.sObjectType.Agreement__c.isAccessible()
                && Schema.sObjectType.Signer__c.isAccessible()) {
                results = Messaging.sendEmail(emails, false);
            }
            Integer failedCount = 0;
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) continue;
                failedCount++;
                List<String> to = emails[i].getToAddresses();
                String addr = (to != null && !to.isEmpty()) ? to[0] : '(unknown recipient)';
                String reason = '';
                for (Messaging.SendEmailError err : results[i].getErrors()) {
                    reason += (String.isBlank(reason) ? '' : '; ') + err.getMessage();
                }
                if (String.isBlank(reason)) reason = 'The address was rejected without a stated reason.';
                System.debug(LoggingLevel.ERROR,
                    'SignForce Email: completion email rejected for ' + addr + ' — ' + reason);
                AuditTrailServiceGuest.log(agr.Id, 'Completion Email Failed', addr, null, null, reason);
            }
            // Nothing got through at all — that is a configuration fault rather
            // than one bad address, and the callers that show errors to an admin
            // (regenerateStampedAndResend) have to keep seeing it.
            if (failedCount > 0 && failedCount == results.size()) {
                throw new AgreementService.AgreementException(
                    'The completion emails could not be sent. All ' + failedCount
                    + ' recipient(s) were rejected. See the agreement audit trail for details.'
                );
            }
        }
    }

    /**
* Build the "download these files" block injected into emails when one or
* more attachments were too big to inline.
*
* Rendered as a <tr><td> so it slots directly into the outer container
* table built by BrandingService (between content-row and footer-row).
*/
    private static String buildDownloadLinksHtml(List<Map<String, String>> links) {
        Map<String, String> t = BrandingServiceGuest.getEmailTokens();
        String html =
            '<tr><td class="sf-px" style="padding:0 48px 32px;font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,Helvetica,Arial,sans-serif;">' +
            '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">' +
            '<tr><td style="border:1px solid ' + t.get('accentBorder') + ';background:' + t.get('accentSurface') + ';padding:18px 20px;border-radius:8px;">' +
            '<p style="margin:0 0 10px;font-size:11px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase;color:' + t.get('accentText') + ';">' +
            'Available for download' +
            '</p>' +
            '<p style="margin:0 0 12px;font-size:12px;line-height:18px;color:' + t.get('accentTextDeep') + ';">' +
            'This document was too large to attach. Use the secure link below to view or download it.' +
            '</p>';
        for (Map<String, String> link : links) {
            String label = link.get('label');
            String url   = link.get('url');
            if (String.isBlank(url)) continue;
            html +=
                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 6px;">' +
                '<tr>' +
                '<td width="18" valign="middle" style="width:18px;">' +
                '<span style="display:inline-block;width:7px;height:7px;border-radius:50%;background:' + t.get('warnCtaBg') + ';"></span>' +
                '</td>' +
                '<td style="font-size:13px;line-height:20px;">' +
                '<a href="' + url.replace('"', '%22') + '" ' +
                'style="color:' + t.get('link') + ';text-decoration:underline;font-weight:500;">' +
                (label != null ? label.escapeHtml4() : 'Download') +
                '</a>' +
                '</td>' +
                '</tr>' +
                '</table>';
        }
        html += '</td></tr></table></td></tr>';
        return html;
    }

    /**
* Strip filesystem-unfriendly chars and limit length so attachment filenames
* don't carry record IDs or look ugly in mail clients.
*/
    private static String sanitizeFileName(String raw) {
        if (String.isBlank(raw)) return 'document';
        String cleaned = raw.replaceAll('[\\\\/:*?"<>|]', '_').trim();
        // Drop ".pdf" / ".docx" / ".doc" suffixes if present (we re-append
        // ".pdf" later) — prevents double extensions like "Contract.docx.pdf".
        String lowerName = cleaned.toLowerCase();
        if (lowerName.endsWith('.pdf')) {
            cleaned = cleaned.substring(0, cleaned.length() - 4);
        } else if (lowerName.endsWith('.docx')) {
            cleaned = cleaned.substring(0, cleaned.length() - 5);
        } else if (lowerName.endsWith('.doc')) {
            cleaned = cleaned.substring(0, cleaned.length() - 4);
        }
        if (cleaned.length() > 80) cleaned = cleaned.substring(0, 80);
        return cleaned;
    }

    // ════════════════════════════════════════════════
    //  ATTACHMENTS AND DOCUMENT BYTES (completion emails)
    // ════════════════════════════════════════════════

    /**
* Decide for ONE document: should we inline-attach (returns AttachmentResult.attachment),
* or send a download link (returns AttachmentResult.downloadUrl)?
*
*   - Skips entirely if document has no fetchable bytes/URL.
*   - For S3 docs > MAX_SINGLE_ATTACHMENT_BYTES, never inline (skip the bytes
*     fetch, just return the presigned URL).
*   - For docs that fit alone but would push runningTotal over MAX_TOTAL, link.
*   - Otherwise inline.
*/
    private class AttachmentResult {
        public Messaging.EmailFileAttachment attachment;
        public Long size;
        public String downloadUrl;
    }

    /**
     * Pull a cloud-stored document's bytes back through the Lambda proxy so they
     * can be attached to the completion email. Only ever called for documents that
     * are already known (or believed) to be small enough to attach — a whole large
     * file would blow the Apex heap, which is why the caller gates on size first.
     *
     * Best-effort: returns null on any failure (including "uncommitted work
     * pending" when the caller's transaction has already done DML), and the caller
     * then falls back to sending a download link.
     */
    private static Blob fetchCloudBytes(Agreement_Document__c doc) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(SignForceConfigServiceGuest.getLambdaEndpoint());
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(120000);
            req.setBody(JSON.serialize(new Map<String, Object>{
                'action'     => 'downloadFromCloud',
                'orgId'      => UserInfo.getOrganizationId(),
                'provider'   => doc.Cloud_Provider__c,
                'fileId'     => doc.Cloud_File_Id__c,
                'rangeStart' => 0,
                'rangeLen'   => (Integer) MAX_SINGLE_ATTACHMENT_BYTES
            }));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.WARN, 'fetchCloudBytes: HTTP ' + res.getStatusCode());
                return null;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            if (body.get('success') != true) {
                System.debug(LoggingLevel.WARN, 'fetchCloudBytes: ' + body.get('message'));
                return null;
            }
            // The proxy reports the FULL file size; anything past one attachment's
            // worth means this document belongs in a link, not an attachment.
            Object rawSize = body.get('size');
            if (rawSize != null && Long.valueOf(String.valueOf(rawSize)) > MAX_SINGLE_ATTACHMENT_BYTES) {
                return null;
            }
            String b64 = (String) body.get('pdfBase64');
            if (String.isBlank(b64)) return null;
            return EncodingUtil.base64Decode(b64);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'fetchCloudBytes failed: ' + e.getMessage());
            return null;
        }
    }

    private static AttachmentResult tryAttachOrLink(
        Agreement_Document__c doc,
        String fileName,
        Long runningTotal
    ) {
        if (doc == null) return null;
        AttachmentResult result = new AttachmentResult();

        // Cloud-stored docs. Now that a connected provider takes documents of ANY
        // size, a small one must still arrive as a real attachment — only pull the
        // bytes back when they'd actually fit, and fall back to the provider's
        // shareable link when they wouldn't (or when the fetch fails).
        // Direct field access (namespace-agnostic inside the package); every
        // caller now SELECTs these fields so there is no unqueried-field risk.
        Boolean isCloud = doc.Storage_Type__c == 'Cloud'
            && String.isNotBlank(doc.Cloud_File_Id__c);
        if (isCloud) {
            Long cloudSize = doc.File_Size_Bytes__c != null ? doc.File_Size_Bytes__c.longValue() : null;
            Boolean couldFit = cloudSize == null
                || (cloudSize <= MAX_SINGLE_ATTACHMENT_BYTES
                    && (runningTotal + cloudSize) <= MAX_TOTAL_ATTACHMENT_BYTES);

            if (couldFit) {
                Blob cloudBytes = fetchCloudBytes(doc);
                if (cloudBytes != null
                    && cloudBytes.size() <= MAX_SINGLE_ATTACHMENT_BYTES
                    && (runningTotal + cloudBytes.size()) <= MAX_TOTAL_ATTACHMENT_BYTES) {
                    Messaging.EmailFileAttachment catt = new Messaging.EmailFileAttachment();
                    catt.setFileName(fileName.endsWith('.pdf') ? fileName : (fileName + '.pdf'));
                    catt.setBody(cloudBytes);
                    catt.setContentType('application/pdf');
                    result.attachment = catt;
                    result.size = (Long) cloudBytes.size();
                    System.debug('tryAttachOrLink: cloud doc inlined (' + cloudBytes.size() + ' bytes)');
                    return result;
                }
            }

            if (String.isNotBlank(doc.S3_Preview_URL__c)) {
                result.downloadUrl = doc.S3_Preview_URL__c;
            } else {
                System.debug('tryAttachOrLink: Cloud doc ' + doc.Id + ' has no shareable URL');
            }
            return result;
        }

        Boolean isS3 = String.isNotBlank(doc.S3_Document_ID__c);
        Long declaredSize = doc.File_Size_Bytes__c != null ? doc.File_Size_Bytes__c.longValue() : null;
        
        // Fast path: known-large S3 doc → skip the fetch, just return presigned URL.
        if (isS3 && declaredSize != null && declaredSize > MAX_SINGLE_ATTACHMENT_BYTES) {
            result.downloadUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
            return result;
        }
        
        // Fast path: would overflow the running total → S3 link, no fetch needed.
        if (isS3 && declaredSize != null && (runningTotal + declaredSize) > MAX_TOTAL_ATTACHMENT_BYTES) {
            result.downloadUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
            return result;
        }
        
        // Otherwise: fetch bytes. Use them inline if they fit, link if they don't.
        Blob bytes = getDocumentBytes(doc, true);
        if (bytes == null) {
            // Bytes fetch failed. If S3-backed, try to send a link as a last resort.
            if (isS3) {
                result.downloadUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
            }
            return result;
        }
        
        Long size = (Long) bytes.size();
        if (size > MAX_SINGLE_ATTACHMENT_BYTES || (runningTotal + size) > MAX_TOTAL_ATTACHMENT_BYTES) {
            // Too big to inline. Switch to link.
            if (isS3) {
                result.downloadUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
            } else {
                // Tier1 doc that's too big — no presigned URL available, skip.
                System.debug('tryAttachOrLink: Tier1 doc ' + doc.Id + ' too big for email and no S3 URL');
            }
            return result;
        }
        
        Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
        att.setFileName(fileName.endsWith('.pdf') ? fileName : (fileName + '.pdf'));
        att.setBody(bytes);
        att.setContentType('application/pdf');
        result.attachment = att;
        result.size = size;
        return result;
    }

    // Document bytes resolver (Tier1 ContentVersion or S3), used by the completion-email attachments.
    public static Blob getDocumentBytes(Agreement_Document__c doc) {
        // Default overload — ORIGINAL behaviour (CV first, whatever its type).
        // Used by hashing/verification so existing Document_Hash__c values stay
        // consistent and no new callouts are introduced in those paths.
        return getDocumentBytes(doc, false);
    }

    public static Blob getDocumentBytes(Agreement_Document__c doc, Boolean preferPdfOverWordCv) {
        if (doc == null) return null;
        
        // Path 1: ContentVersion (Tier1 original or Certificate)
        if (String.isNotBlank(doc.Content_Version_ID__c)) {
            try {
                ContentVersion cv = [
                    SELECT VersionData, FileExtension FROM ContentVersion
                    WHERE Id = :doc.Content_Version_ID__c LIMIT 1
                ];
                String cvExt = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';
                if (preferPdfOverWordCv && (cvExt == 'doc' || cvExt == 'docx')) {
                    // EMAIL PATH ONLY: the CV behind this record is a WORD file
                    // (e.g. the original DOCX of an auto-created agreement).
                    // Emailing those bytes as ".pdf" produces a corrupt
                    // attachment, so skip the CV and fall through to the S3
                    // copy below — that's the converted PDF.
                    System.debug('getDocumentBytes: CV is Word (' + cvExt + '), using S3 PDF instead');
                } else {
                    System.debug('getDocumentBytes: CV path success for ' + doc.Id);
                    return cv.VersionData;
                }
            } catch (Exception e) {
                System.debug('getDocumentBytes: CV fetch failed: ' + e.getMessage());
            }
        }
        
        // Path 2: S3-backed (Stamped or Tier2/Tier3)
        if (String.isBlank(doc.S3_Document_ID__c)) {
            System.debug('getDocumentBytes: no CV or S3 ID');
            return null;
        }
        
        System.debug('getDocumentBytes: S3 path attempt for ' + doc.S3_Document_ID__c);
        
        // Try the cached presigned URL FIRST (set at stamping time, no callout needed)
        String presignedUrl = doc.S3_Preview_URL__c;
        Boolean isCachedUrlExpired = false;
        
        // S3 presigned URLs expire after 24 hours typically. Check timestamp in URL.
        if (String.isNotBlank(presignedUrl)) {
            // Try the cached URL first — no Lambda callout needed
            try {
                HttpRequest pdfReq = new HttpRequest();
                pdfReq.setEndpoint(presignedUrl);
                pdfReq.setMethod('GET');
                pdfReq.setTimeout(120000);
                pdfReq.setHeader('Accept', 'application/pdf');
                HttpResponse pdfRes = new Http().send(pdfReq);
                
                if (pdfRes.getStatusCode() == 200) {
                    Blob result = pdfRes.getBodyAsBlob();
                    System.debug('getDocumentBytes: S3 cached URL success, ' + result.size() + ' bytes');
                    return result;
                } else if (pdfRes.getStatusCode() == 403) {
                    // 403 typically means URL expired — fall through to refresh
                    System.debug('getDocumentBytes: cached URL expired (403), refreshing');
                    isCachedUrlExpired = true;
                } else {
                    System.debug('getDocumentBytes: cached URL HTTP ' + pdfRes.getStatusCode());
                }
            } catch (Exception e) {
                System.debug('getDocumentBytes: cached URL fetch failed: ' + e.getMessage());
            }
        }
        
        // Only call Lambda for fresh URL if cached URL was missing or expired
        if (String.isBlank(presignedUrl) || isCachedUrlExpired) {
            try {
                String freshUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
                if (String.isBlank(freshUrl)) {
                    System.debug('getDocumentBytes: fresh URL blank');
                    return null;
                }
                
                HttpRequest pdfReq = new HttpRequest();
                pdfReq.setEndpoint(freshUrl);
                pdfReq.setMethod('GET');
                pdfReq.setTimeout(120000);
                pdfReq.setHeader('Accept', 'application/pdf');
                HttpResponse pdfRes = new Http().send(pdfReq);
                
                if (pdfRes.getStatusCode() != 200) {
                    System.debug('getDocumentBytes: fresh URL HTTP ' + pdfRes.getStatusCode());
                    return null;
                }
                Blob result = pdfRes.getBodyAsBlob();
                System.debug('getDocumentBytes: ✅ S3 fresh URL success, ' + result.size() + ' bytes');
                return result;
            } catch (Exception e) {
                System.debug('getDocumentBytes: fresh URL fetch failed: ' + e.getMessage());
                return null;
            }
        }
        
        return null;
    }

    // ════════════════════════════════════════════════
    //  DOCUMENT URL
    // ════════════════════════════════════════════════

    /**
* Returns a fresh presigned URL for the given S3 doc ID. Used both for fetching
* bytes inline AND for embedding download links in completion emails.
*/
    public static String getS3PresignedUrlForDoc(String s3DocId) {
        if (String.isBlank(s3DocId)) return null;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(SignForceConfigServiceGuest.getLambdaEndpoint());
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);
            req.setBody(JSON.serialize(new Map<String, Object>{
                'action' => 'getUrl',
                    'orgId'  => UserInfo.getOrganizationId(),
                    'docId'  => s3DocId
                    }));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                System.debug('getS3PresignedUrlForDoc: Lambda HTTP ' + res.getStatusCode());
                return null;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return (String) body.get('url');
        } catch (Exception e) {
            System.debug('getS3PresignedUrlForDoc: ' + e.getMessage());
            return null;
        }
    }

    // ════════════════════════════════════════════════
    //  EMAIL HELPERS (copies - sharing-sensitive ones must stay in this without-sharing class)
    // ════════════════════════════════════════════════

    // Resolve the org default timezone once and cache it so every formatted
    // timestamp (emails, certs, stamped copies) renders in the SAME local zone
    // with a zone label, instead of raw UTC.
    private static String ORG_TZ;
    private static String orgTz() {
        if (ORG_TZ == null) {
            ORG_TZ = [SELECT TimeZoneSidKey FROM Organization LIMIT 1].TimeZoneSidKey;
        }
        return ORG_TZ;
    }

    /** Tokens, or null if even the token layer is unavailable. */
    private static Map<String, String> safeTokens() {
        try { return BrandingServiceGuest.getEmailTokens(); } catch(Exception e) { return null; }
    }
    private static String tok(Map<String, String> t, String key, String fallback) {
        if (t == null) return fallback;
        String v = t.get(key);
        return String.isBlank(v) ? fallback : v;
    }

    private static String getEmailHeader() {
        try {
            return BrandingServiceGuest.getEmailHeader();
        } catch(Exception e) {
            // Last-resort shell if the branded header fails — still brand-named
            // and brand-coloured wherever the token layer is still reachable.
            Map<String, String> t = safeTokens();
            return '<div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;">' +
                '<div style="background:' + tok(t, 'headerBg', '#0a1628') + ';padding:24px;text-align:center;">' +
                '<h1 style="color:' + tok(t, 'brandAccent', '#f59e0b') + ';margin:0;font-size:24px;letter-spacing:1px;">' +
                tok(t, 'companyName', 'SignForce').escapeHtml4() + '</h1>' +
                '</div>';
        }
    }

    private static String getEmailFooter() {
        try {
            return BrandingServiceGuest.getEmailFooter();
        } catch(Exception e) {
            Map<String, String> t = safeTokens();
            return '<div style="background:' + tok(t, 'canvas', '#f6f7f9') + ';padding:16px;text-align:center;">' +
                '<p style="color:' + tok(t, 'textMuted', '#94a3b8') + ';font-size:11px;margin:0;">Powered by ' +
                tok(t, 'companyName', 'SignForce').escapeHtml4() + '</p>' +
                '</div></div>';
        }
    }

    private static void sendSignerEmail(Signer__c signer, Agreement__c agr) {
        sendSignerEmail(signer, agr, null, null);
    }

    /**
     * True when a User.Name is fit to print as a person's name in an email.
     *
     * Salesforce does not always hand back a readable name. When the running
     * user cannot see the queried user — and a guest signing transaction sending
     * the NEXT sequential signer's invitation is exactly that case — the platform
     * substitutes a placeholder built from the record's numeric id: the literal
     * "User" followed by ~20 digits ("User17823068604142635227"). That value is
     * not blank and it survives every String.isNotBlank guard, which is how a raw
     * id reached the "From" line of a signature request. A bare 15- or
     * 18-character record id gets the same treatment.
     *
     * Rejecting the placeholder leaves senderName empty, so the caller falls back
     * to the branded company name — the right thing to show someone who is about
     * to sign something.
     */
    @TestVisible
    /**
     * Display name for the "From" row, resolved once per agreement per transaction.
     *
     * sendSignerEmail runs once per signer, so resolving this inline cost two SOQL
     * on every iteration even though neither query varies by signer — enough to
     * halve the number of parallel signers a send could survive before hitting the
     * 100-query ceiling. Cached in a static instead: the values cannot change
     * mid-transaction.
     *
     * Prefers the agreement's CREATOR over its owner, and shows a name only when
     * it belongs to a Standard user AND actually reads as a name. Salesforce
     * substitutes a placeholder like "User17823068604142635227" when the running
     * user cannot see the queried user — which is exactly the case when a guest
     * signing transaction sends the next sequential signer their invitation. Blank
     * here means the caller falls back to the branded company name.
     */
    private static Map<Id, String> senderNameCache = new Map<Id, String>();

    private static String resolveSenderName(Id agreementId) {
        if (senderNameCache.containsKey(agreementId)) return senderNameCache.get(agreementId);

        String senderName = '';
        try {
            Agreement__c who = [
                SELECT CreatedById, OwnerId FROM Agreement__c
                WHERE Id = :agreementId LIMIT 1
            ];
            Map<Id, User> byId = new Map<Id, User>([
                SELECT Id, Name, UserType FROM User
                WHERE Id IN :new Set<Id>{ who.CreatedById, who.OwnerId }
            ]);
            User creator = byId.get(who.CreatedById);
            User owner   = byId.get(who.OwnerId);
            if (creator != null && creator.UserType == 'Standard' && isDisplayableName(creator.Name)) {
                senderName = creator.Name;
            } else if (owner != null && owner.UserType == 'Standard' && isDisplayableName(owner.Name)) {
                senderName = owner.Name;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'resolveSenderName fell back to branding: ' + e.getMessage());
        }
        senderNameCache.put(agreementId, senderName);
        return senderName;
    }

    private static Boolean isDisplayableName(String candidate) {
        if (String.isBlank(candidate)) return false;
        String n = candidate.trim();
        if (Pattern.matches('(?i)^user\\d{10,}$', n)) return false;
        if (n.length() == 15 || n.length() == 18) {
            try {
                Id.valueOf(n);
                return false;
            } catch (Exception e) {
                // Not an id, just a name that happens to be that long — allow it.
            }
        }
        return true;
    }

    private static void sendSignerEmail(Signer__c signer, Agreement__c agr, String subjectOverride, String messageOverride) {
        String baseUrl = SignForceConfigServiceGuest.getSigningSiteBaseUrl();
        String signingUrl = baseUrl + '/signature?token=' + signer.Access_Token__c;
        String headerHtml = getEmailHeader();
        String footerHtml = getEmailFooter();
        
        // Default message falls back to the agreement's stored message-to-signers.
        String effectiveMessage = String.isNotBlank(messageOverride)
            ? messageOverride
            : (String.isNotBlank(agr.Message_to_Signers__c) ? agr.Message_to_Signers__c : null);
                
                String effectiveSubject = String.isNotBlank(subjectOverride)
                ? subjectOverride
                : ('Action Required: Please sign "' + agr.Name + '"');
                    
                    // Sender display name for the meta row.
                    //
                    // The person who CREATED the agreement, not its owner. With
                    // sequential signing, signer 2's email goes out from the guest
                    // signing transaction, and ownership can also sit with an
                    // integration or auto-provisioned user — which is how signers
                    // ended up greeted by "From User17786692354307417404". Only a
                    // Standard user's name is ever shown; anything else (guest,
                    // automated process, integration users) falls through to the
                    // company name from branding, which is always presentable.
                    //
                    // The UserType gate alone is not enough: Name itself can come
                    // back as a placeholder id rather than a person (see
                    // isDisplayableName), so each candidate is checked before it is
                    // allowed onto the "From" line.
                    // Resolved through a per-transaction cache: sendForSignature
                    // calls this method once PER SIGNER, so querying the agreement
                    // and its users here cost two SOQL on every iteration and ate
                    // the 100-query ceiling as signer count grew.
                    String senderName = resolveSenderName(agr.Id);

        String sentDateFmt = DateTime.now().format('MMM dd, yyyy', orgTz());
        
        String fromName = String.isNotBlank(senderName)
            ? senderName : BrandingServiceGuest.getEmailTokens().get('companyName');
        String body =
            headerHtml +
            BrandingServiceGuest.emailBodyOpen() +
            BrandingServiceGuest.pill('warning', 'SIGNATURE REQUESTED') +
            BrandingServiceGuest.heading('You have a document to sign') +
            BrandingServiceGuest.lead(
                'Please review and sign ' + BrandingServiceGuest.emphasis(agr.Name) +
                ' at your earliest convenience.') +
            BrandingServiceGuest.metaCard(
                new List<String>{ 'From', 'Sent' },
                new List<String>{ fromName, sentDateFmt }) +
            (String.isNotBlank(effectiveMessage)
                ? BrandingServiceGuest.noteCard('warning', 'Message from sender', effectiveMessage) : '') +
            BrandingServiceGuest.cta(signingUrl, 'Review & sign →', 'brand') +
            BrandingServiceGuest.fallbackLink(signingUrl) +
            BrandingServiceGuest.stepsStrip('What happens next',
                new List<String>{ '1. Open', '2. Review', '3. Sign' },
                new List<String>{
                    'Click the button above to open the document.',
                    'Read through and fill any required fields.',
                    'Adopt your signature and submit. Done.' }) +
            BrandingServiceGuest.footnote('This link is unique to you — please don\'t forward this email. If you weren\'t expecting this, you can safely ignore it.') +
            BrandingServiceGuest.emailBodyClose() +
            footerHtml;
        
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ signer.Email__c });
        email.setSubject(effectiveSubject);
        String owaId = AgreementService.getOwaId();
        if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
        email.setHtmlBody(body);
        
        // CRUD: this message is built entirely from the Signer__c and
        // Agreement__c fields read above, so their read access gates the send.
        // Both are granted read to the Site Guest User, so guest signing is
        // unaffected and the branch is always taken.
        if (Schema.sObjectType.Signer__c.isAccessible()
            && Schema.sObjectType.Agreement__c.isAccessible()) {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
        }
        signer.Status__c = 'Sent';
        update signer;
        AuditTrailServiceGuest.log(agr.Id, 'Email Delivered', signer.Email__c, null, null);
    }
}
