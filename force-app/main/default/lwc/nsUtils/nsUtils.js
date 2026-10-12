/**
 * nsUtils — namespace-safe helpers for managed-package LWCs.
 *
 * In a managed package's OWN packaging org, an Apex method that returns a raw
 * SObject serializes its packaged field keys WITH the namespace prefix
 * (e.g. "NSIQ_SignForce__Object_API_Name__c"), while the component accesses
 * the bare name ("Object_API_Name__c") -> undefined -> blank fields.
 *
 * stripNs() recursively removes the package namespace prefix from every object
 * key so the LWC can read fields by their bare API name. It is safe in BOTH
 * contexts: in a subscriber (installed) org the keys are already bare, so it
 * is a harmless no-op.
 */
const NS = '';

/**
 * Build a namespace-correct Visualforce page path, e.g.
 *   vfPageUrl('PDFPreview') -> '/apex/NSIQ_SignForce__PDFPreview'
 * In a managed package the VF page is served under the namespace prefix in
 * EVERY org (packaging + subscriber), so a hardcoded '/apex/PDFPreview' would
 * 404. Append your query string to the result.
 */
export function vfPageUrl(pageName) {
    return '/apex/' + NS + pageName;
}

export function stripNs(value) {
    if (Array.isArray(value)) {
        return value.map(stripNs);
    }
    if (value !== null && typeof value === 'object') {
        const out = {};
        for (const key of Object.keys(value)) {
            const isMatch = key.toLowerCase().startsWith(NS.toLowerCase());
            const bareKey = isMatch ? key.slice(NS.length) : key;
            out[bareKey] = stripNs(value[key]);
        }
        return out;
    }
    return value;
}