/**
 * TemplatePaddingStripQueueable — removes the blank-space padding an author left
 * after a {{merge tag}}, then rebuilds the template's PDF preview.
 *
 * Runs asynchronously because the upload that triggers it has already committed
 * DML, and Apex refuses a callout once a transaction has uncommitted work.
 *
 * Ordering matters: the preview must be rebuilt AFTER the padding is gone, because
 * field placements in the editor are captured against that preview. Building it
 * first would anchor every field to text that is about to move.
 *
 * Failures are non-fatal — the template simply keeps its original padding.
 */
public with sharing class TemplatePaddingStripQueueable implements Queueable, Database.AllowsCallouts {

    private Id templateId;

    public TemplatePaddingStripQueueable(Id templateId) {
        this.templateId = templateId;
    }

    public void execute(QueueableContext ctx) {
        Boolean changed = false;
        try {
            Map<String, Object> res = DocumentGenerationService.stripTemplatePadding(templateId);
            changed = (res != null && res.get('changed') == true);
            if (changed) {
                System.debug(LoggingLevel.INFO,
                    'Padding stripped from template ' + templateId +
                    ': ' + res.get('removedChars') + ' char(s) across ' +
                    res.get('paragraphs') + ' paragraph(s)');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'TemplatePaddingStripQueueable failed (non-fatal): ' + e.getMessage());
        }

        // stripTemplatePadding queues the preview itself when it rewrote the file.
        // When it did not, the preview still has to be built for a new upload.
        // `true` = upload chain: the preview job mirrors the final DOCX to any
        // connected cloud provider once it finishes.
        if (!changed) {
            try { System.enqueueJob(new TemplatePreviewPdfQueueable(templateId, true)); }
            catch (Exception e) { /* preview falls back to on-demand conversion */ }
        }
    }
}