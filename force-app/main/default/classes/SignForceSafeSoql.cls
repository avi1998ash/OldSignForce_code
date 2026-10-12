/**
 * SignForceSafeSoql — input sanitization for any string that goes into
 * dynamic SOQL.
 *
 * ────────────────────────────────────────────────────────────────────────
 * PURPOSE
 * ────────────────────────────────────────────────────────────────────────
 *
 * Bind variables are the right answer for user-supplied VALUES (use
 * `WHERE field = :userInput`). But SOQL has parts that can't be bound:
 *
 *   - Object names: 'SELECT ... FROM ' + objectName
 *   - Field names: 'SELECT ' + fieldName + ' FROM ...'
 *   - ORDER BY clauses: 'ORDER BY ' + sortColumn
 *
 * If those come from user input, they need validation against describes
 * before concatenation. This class provides those validators.
 *
 * For VALUE escaping (the rare case where you can't use bind variables),
 * we expose escapeSingleQuotes as a clean wrapper.
 *
 * ────────────────────────────────────────────────────────────────────────
 * USAGE PATTERNS
 * ────────────────────────────────────────────────────────────────────────
 *
 * Validate object name before dynamic query:
 *   String objName = SignForceSafeSoql.validateObjectName(userInput);
 *   String soql = 'SELECT Id FROM ' + objName + ' WHERE ...';
 *
 * Validate field name:
 *   String fieldName = SignForceSafeSoql.validateFieldName(
 *       Account.SObjectType, userInputField
 *   );
 *
 * Validate sort direction:
 *   String dir = SignForceSafeSoql.validateSortDirection(userInput);  // 'ASC' or 'DESC'
 *
 * Escape literal value (last resort — prefer bind variables):
 *   String escaped = SignForceSafeSoql.escapeLiteral(userInput);
 *   String soql = 'SELECT Id FROM Account WHERE Name = \'' + escaped + '\'';
 *
 * ────────────────────────────────────────────────────────────────────────
 * IMPORTANT
 * ────────────────────────────────────────────────────────────────────────
 *
 * If you find yourself reaching for escapeLiteral, STOP and ask whether
 * a bind variable would work. 99% of the time it does, and bind variables
 * are categorically safer than escaping.
 */
public with sharing class SignForceSafeSoql {

    /**
     * Custom exception thrown when validation fails.
     */
    public class InvalidSoqlInputException extends Exception {}

    /**
     * Confirm objectName resolves to a real SObject in this org. Returns the
     * canonical API name (case-corrected). Throws if not found.
     */
    public static String validateObjectName(String objectName) {
        if (String.isBlank(objectName)) {
            throw new InvalidSoqlInputException('Object name cannot be blank.');
        }
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Schema.SObjectType objType = gd.get(objectName);
        if (objType == null) objType = gd.get(objectName.toLowerCase());
        if (objType == null) {
            // Managed-package fallback: getGlobalDescribe() keys are namespaced
            // (ns__agreement__c), so resolve a bare name via the namespaced key.
            String target = objectName.toLowerCase();
            for (String k : gd.keySet()) {
                if (k.endsWith('__' + target)) { objType = gd.get(k); break; }
            }
        }
        if (objType == null) {
            throw new InvalidSoqlInputException('Unknown object: ' + objectName);
        }
        return objType.getDescribe().getName();
    }

    /**
     * Confirm fieldName exists on the given object. Returns the canonical
     * API name. Throws if not found.
     */
    public static String validateFieldName(Schema.SObjectType objType, String fieldName) {
        if (objType == null) {
            throw new InvalidSoqlInputException('Object type cannot be null.');
        }
        if (String.isBlank(fieldName)) {
            throw new InvalidSoqlInputException('Field name cannot be blank.');
        }
        Map<String, Schema.SObjectField> fields = objType.getDescribe().fields.getMap();
        Schema.SObjectField field = fields.get(fieldName.toLowerCase());
        if (field == null) {
            // Managed-package fallback: field-map keys are namespaced
            // (ns__status__c), so resolve a bare name via the namespaced key.
            String target = fieldName.toLowerCase();
            for (String k : fields.keySet()) {
                if (k.endsWith('__' + target)) { field = fields.get(k); break; }
            }
        }
        if (field == null) {
            throw new InvalidSoqlInputException(
                'Unknown field: ' + fieldName + ' on '
                + objType.getDescribe().getName()
            );
        }
        return field.getDescribe().getName();
    }

    /**
     * Validate a list of field names against an object. Returns the
     * canonical API names. Throws on the first unknown field.
     */
    public static List<String> validateFieldNames(
        Schema.SObjectType objType, List<String> fieldNames
    ) {
        List<String> validated = new List<String>();
        for (String f : fieldNames) {
            validated.add(validateFieldName(objType, f));
        }
        return validated;
    }

    /**
     * Validate a sort direction string. Returns 'ASC' or 'DESC' uppercased.
     * Throws on anything else.
     */
    public static String validateSortDirection(String dir) {
        if (String.isBlank(dir)) return 'ASC'; // sensible default
        String upper = dir.trim().toUpperCase();
        if (upper != 'ASC' && upper != 'DESC') {
            throw new InvalidSoqlInputException(
                'Invalid sort direction: ' + dir + ' (expected ASC or DESC)'
            );
        }
        return upper;
    }

    /**
     * Validate a LIMIT value. Caps to a sensible maximum to prevent
     * abuse via huge LIMIT clauses.
     */
    public static Integer validateLimit(Integer limitVal, Integer maxAllowed) {
        if (limitVal == null || limitVal < 1) return 1;
        if (limitVal > maxAllowed) return maxAllowed;
        return limitVal;
    }

    /**
     * Escape a string literal for inclusion in SOQL. PREFER BIND VARIABLES.
     * This is for the rare case where bind variables aren't usable
     * (e.g., LIKE patterns built dynamically).
     *
     * Wraps Salesforce's String.escapeSingleQuotes which is the standard
     * Apex-side escape. Adds an explicit null-safety guard.
     */
    public static String escapeLiteral(String input) {
        if (String.isBlank(input)) return '';
        return String.escapeSingleQuotes(input);
    }

    /**
     * Build a SOQL "IN (...)" clause from a list of safe values.
     * Used when you have a list of literal strings that need to go into
     * a SOQL "IN" clause without bind variables (uncommon — bind variables
     * accept lists).
     */
    public static String buildInClause(List<String> values) {
        if (values == null || values.isEmpty()) return '()';
        List<String> escaped = new List<String>();
        for (String v : values) {
            escaped.add('\'' + escapeLiteral(v) + '\'');
        }
        return '(' + String.join(escaped, ', ') + ')';
    }
}