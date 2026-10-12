/**
 * signforceErrors — turns a raw failure into something a person can act on.
 *
 * WHY THIS EXISTS. What Apex hands back is written for a developer reading a
 * stack trace. DocumentGenerationService stores the failure as
 * "<TypeName>: <message>\n\n<stack trace>", so Error_Message__c on a failed log
 * row reads like:
 *
 *   System.CalloutException: Read timed out
 *
 *   Class.DocumentGenerationService.render: line 88, column 1
 *
 * Putting that on screen tells the reader nothing they can do. Worse, in the
 * bulk screens the only sign of trouble was a toast that vanished after a few
 * seconds and a "2 failed" chip — so a run could fail and leave no trace on
 * screen at all.
 *
 * Every entry below is matched against a message this app actually produces:
 * the literal strings thrown by DocumentGenerationService, MergeContextBuilder,
 * TemplateService and SignForceBulkGenerate, plus the platform exceptions those
 * paths surface. The raw text is never discarded — it is returned as `detail`
 * so an admin can still open it when the friendly line is not enough.
 */

/* Ordered most specific first: the first rule whose every `any` term appears
   wins, so a broad rule placed early would swallow the precise ones. */
const RULES = [
    {
        any: ['uncommitted work pending'],
        title: 'The previous step was still finishing',
        text: 'eSignforce was still saving the document before this one. Run this record again on its own and it should go through.'
    },
    {
        any: ['lambda endpoint is not configured', 'endpoint is not configured'],
        title: 'eSignforce is not connected yet',
        text: 'The document service has not been set up in this org. An administrator can finish this on the eSignforce Admin Config tab.'
    },
    {
        any: ['template file is missing', 'no contentversion found for document'],
        title: 'The template has no document',
        text: 'The file attached to this template is missing or was deleted. Open the template on the Dynamic Document tab and upload it again.'
    },
    {
        any: ['template has no target object', 'target object api name is required',
              'object api name is required', 'unknown object'],
        title: 'The template is not finished',
        text: 'This template does not say which kind of record it applies to. An administrator can set that on the Dynamic Document tab.'
    },
    {
        any: ['template not found', 'template is null', 'template id is required'],
        title: 'That template is gone',
        text: 'The template no longer exists — it may have been deleted while this screen was open. Refresh the page and pick another one.'
    },
    {
        any: ['invalid_session_id', 'session expired', 'unauthorized', 'http 401'],
        title: 'Your session has expired',
        text: 'Refresh the page, sign in again, and run this once more. Nothing was changed.'
    },
    {
        // A merge tag pointing at a field that is misspelled, renamed or gone.
        //
        // "does not exist on" is here because MergeContextBuilder words it as
        //   Field "AccouNuber" does not exist on Account
        // and the field name sits between "Field" and "does not exist", so the
        // obvious needle never matched and every one of these fell through to
        // the generic fallback.
        any: ['does not exist on', 'no such column', 'invalid field',
              'field does not exist', 'mergeexception', 'didn\'t understand relationship'],
        title: 'A tag points at a field that does not exist',
        text: 'The template has a merge tag for a field that is not on this object — usually a typo, or a field that has been renamed. Open the template and check the Tags tab.',
        // The message already names the offending field. Naming it back is the
        // difference between "check your tags" and "fix this one".
        refine: (raw) => {
            const m = raw.match(/Field\s+"([^"]+)"\s+does not exist on\s+([A-Za-z0-9_]+)/i);
            if (!m) return null;
            return `The template has a tag for a field called "${m[1]}", which does not exist on ${m[2]}. `
                 + 'It is almost always a spelling mistake. Open the template, go to the Tags tab, '
                 + 'and correct that tag — then run these records again.';
        }
    },
    {
        // The renderer refused to open the .docx at all because a tag is
        // malformed. This surfaced as a raw Node stack trace from
        // docxtemplater — paths under /var/task/node_modules and all — which
        // told the reader nothing except that something is broken.
        //
        // Placed before the field rule: a compile failure never gets as far as
        // resolving fields, so it must not be mistaken for a bad field name.
        any: ['unclosed tag', 'unopened tag', 'template compile failed',
              'duplicate open tag', 'duplicate close tag', 'templateerror',
              'raw tag not in paragraph', 'closing tag does not match'],
        title: 'A merge tag in the template is written wrongly',
        text: 'One of the {{tags}} in the Word file is not closed properly — usually a missing "}}", '
            + 'or a tag that Word has split apart because part of it was edited or re-formatted. '
            + 'Open the template, fix that tag, upload the file again, then re-run.',
        refine: (raw) => {
            const lower = String(raw).toLowerCase();

            // docxtemplater names the offending text in "context" or "xtag" when
            // it can. Quoting it back is the difference between "check your tags"
            // and "look at this one".
            let snippet = null;
            const ctx = raw.match(/"context"\s*:\s*"([^"]{1,80})"/);
            const xt = raw.match(/"xtag"\s*:\s*"([^"]{1,80})"/);
            if (ctx) snippet = ctx[1];
            else if (xt) snippet = xt[1];

            const kind = lower.includes('unclosed tag')
                ? 'is missing its closing "}}"'
                : lower.includes('unopened tag')
                    ? 'has a closing "}}" with no opening "{{"'
                    : lower.includes('duplicate open tag')
                        ? 'has "{{" twice with no "}}" between them'
                        : lower.includes('duplicate close tag')
                            ? 'has "}}" twice'
                            : null;
            if (!kind && !snippet) return null;

            let out = snippet
                ? `A merge tag near "${snippet}" ${kind || 'is not written correctly'}.`
                : `A merge tag in the template ${kind}.`;
            out += ' Open the template in Word and correct it. If it looks right on screen, '
                 + 'delete the whole tag and retype it in one go — Word sometimes splits a tag '
                 + 'internally when it has been edited a character at a time, and that breaks it '
                 + 'even though it reads correctly. Then re-upload the file and run this again.';
            return out;
        }
    },
    {
        any: ['field_custom_validation_exception', 'validation rule'],
        title: 'A rule on the record blocked this',
        text: 'A validation rule on the record refused the save. The record itself has to be corrected before a document can be produced from it.'
    },
    {
        any: ['required_field_missing'],
        title: 'A required field is empty',
        text: 'A field the record needs is blank. Fill it in on the record, then run this again.'
    },
    {
        any: ['insufficient_access', 'insufficient privileges', 'you do not have access',
              'record not found or not accessible'],
        title: 'You cannot access this record',
        text: 'The record was deleted, or it is not shared with you. Ask an administrator to check your access to it.'
    },
    {
        any: ['storage_limit_exceeded', 'contentpublication limit', 'file storage'],
        title: 'The org has run out of file space',
        text: 'Salesforce would not store another file. This clears on its own within 24 hours, or an administrator can free up space.'
    },
    {
        any: ['limit_exceeded', 'too many soql', 'too many dml', 'cpu time limit',
              'apex heap size', 'too many query rows'],
        title: 'Too much was processed at once',
        text: 'The run went past what Salesforce allows in one go. Try it again with fewer records at a time.'
    },
    {
        // Anything on the way to, or back from, the rendering service.
        any: ['read timed out', 'unable to tunnel', 'connection reset',
              'unexpected end of stream', 'calloutexception', 'lambda call failed',
              'pdf conversion failed', 'pdf fetch failed', 'pdf fetch returned no data',
              'socket', 'timed out'],
        title: 'The document service did not respond',
        text: 'eSignforce could not reach the service that builds the document, or it took too long. This is usually temporary — wait a moment and run it again.'
    },
    {
        any: ['unable to find', 'no valid recipients'],
        title: 'Nothing to send to',
        text: 'None of the rows had a usable email address. Check the list and try again.'
    },
    {
        // Template parsing / merge internals blowing up.
        any: ['de-reference a null object', 'nullpointerexception', 'string index out of range',
              'jsonexception', 'listexception', 'index out of bounds'],
        title: 'The template could not be processed',
        text: 'Something in the template stopped the document being built — most often a tag that is written incorrectly. Open the template and check the Tags tab.'
    }
];

/* Deliberately does not promise "the technical details below": this text also
   appears in compact rows that have no detail panel, and pointing at something
   that is not on screen is worse than saying nothing. */
const FALLBACK = {
    title: 'The document could not be created',
    text: 'This record was left exactly as it was. Try it again — if it keeps failing, open the technical details and send them to your administrator.'
};

/**
 * @param {*} raw  an Apex error object, an Error, or a plain message string
 * @returns {{title: string, text: string, detail: string}}
 *          `detail` is the untouched original, for an admin to expand.
 */
export function friendlyError(raw) {
    const detail = rawText(raw);
    const hay = detail.toLowerCase();

    const hit = RULES.find((r) => r.any.some((needle) => hay.includes(needle)));
    const chosen = hit || FALLBACK;

    // A rule may pull specifics out of the raw text — the field that is
    // misspelled, for instance. It falls back to the generic sentence whenever
    // the message is not in the shape it expected.
    let text = chosen.text;
    if (chosen.refine) {
        try {
            text = chosen.refine(detail) || chosen.text;
        } catch (e) {
            text = chosen.text;
        }
    }

    return { title: chosen.title, text, detail };
}

/** Just the sentence, for places with no room for a title. */
export function friendlyMessage(raw) {
    return friendlyError(raw).text;
}

/**
 * Digs the message out of whatever the caller was handed.
 *
 * An Apex @AuraEnabled failure arrives as { body: { message } }, a page-level
 * error as { body: [{ message }] }, a JS throw as an Error, and a log row's
 * Error_Message__c as a bare string.
 */
function rawText(raw) {
    if (!raw) return '';
    if (typeof raw === 'string') return raw;
    if (Array.isArray(raw)) return raw.map(rawText).join(' ');

    const body = raw.body;
    if (body) {
        if (typeof body === 'string') return body;
        if (Array.isArray(body)) return body.map((b) => b && b.message).filter(Boolean).join(' ');
        if (body.message) return body.message;
        if (body.pageErrors && body.pageErrors.length) {
            return body.pageErrors.map((p) => p.message).join(' ');
        }
    }
    return raw.message || raw.statusText || String(raw);
}