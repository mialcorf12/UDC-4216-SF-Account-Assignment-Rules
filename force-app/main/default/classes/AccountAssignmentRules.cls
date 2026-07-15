/**
 * AccountAssignmentRules
 *
 * Metadata-driven Account assignment engine.
 * Evaluates Account_Assignment_Rule__mdt records in ascending Order__c and applies
 * the first matching rule to set OwnerId, Integration_Specialist__c, and
 * Development_Specialist__c on newly inserted Accounts owned by SysAdmin users.
 *
 * Key design constraints:
 * - All SOQL runs ONCE before the processing loop (bulkification).
 * - A single DML statement updates all staged Accounts after the loop.
 * - isCatchAll() prevents all-blank rules from firing.
 * - sendInvalidOwnerAlert() is @TestVisible and suppressed in test context
 *   via skipEmailInTest.
 *
 * Debug log strings are in Spanish per project language contract:
 *   'se aplico la regla #N'
 *   'no cumplio con ninguna regla establecida'
 *   'regla #N fallida — OwnerId inválido: <Id>'
 */
public with sharing class AccountAssignmentRules {

    // Set to true in test context to suppress email sending (see sendInvalidOwnerAlert).
    @TestVisible
    private static Boolean skipEmailInTest = false;

    // ─── Public Entry Point ───────────────────────────────────────────────────

    /**
     * Main entry point called from AccountTrigger on after insert.
     * Filters Accounts to SysAdmin owners, then applies matching MDT rules.
     *
     * @param newAccounts  Trigger.new — the inserted Account records.
     */
    public static void assign(List<Account> newAccounts) {
        if (newAccounts == null || newAccounts.isEmpty()) {
            return;
        }

        // ── 1. Profile filter ────────────────────────────────────────────────
        List<Profile> sysAdminProfiles = [
            SELECT Id FROM Profile
            WHERE Name IN ('uLab SysAdmin', 'System Administrator')
        ];
        Set<Id> profileIds = new Set<Id>();
        for (Profile p : sysAdminProfiles) {
            profileIds.add(p.Id);
        }

        Set<Id> accountOwnerIds = new Set<Id>();
        for (Account acc : newAccounts) {
            if (acc.OwnerId != null) {
                accountOwnerIds.add(acc.OwnerId);
            }
        }

        List<User> sysAdminUsers = [
            SELECT Id FROM User
            WHERE ProfileId IN :profileIds
            AND Id IN :accountOwnerIds
        ];
        Set<Id> sysAdminUserIds = new Set<Id>();
        for (User u : sysAdminUsers) {
            sysAdminUserIds.add(u.Id);
        }

        // Filter to only SysAdmin-owned accounts
        List<Account> filteredAccounts = new List<Account>();
        for (Account acc : newAccounts) {
            if (sysAdminUserIds.contains(acc.OwnerId)) {
                filteredAccounts.add(acc);
            }
        }
        if (filteredAccounts.isEmpty()) {
            return;
        }

        // ── 2. MDT query (once, ordered) ─────────────────────────────────────
        List<Account_Assignment_Rule__mdt> rules = [
            SELECT Order__c, BillingCountry__c, BillingState__c, BillingPostalCode__c,
                   OwnerId__c, Integration_Specialist__c, Development_Specialist__c
            FROM Account_Assignment_Rule__mdt
            WHERE MasterLabel != null
            ORDER BY Order__c ASC
        ];

        // ── 3. Owner validity map (once, before loop) ─────────────────────────
        Set<String> ruleOwnerIdStrings = new Set<String>();
        for (Account_Assignment_Rule__mdt rule : rules) {
            if (String.isNotBlank(rule.OwnerId__c)) {
                ruleOwnerIdStrings.add(rule.OwnerId__c);
            }
        }
        // Convert strings to Ids defensively (handles malformed values)
        Set<Id> ruleOwnerIds = new Set<Id>();
        for (String ownerIdStr : ruleOwnerIdStrings) {
            try {
                ruleOwnerIds.add(Id.valueOf(ownerIdStr));
            } catch (Exception e) {
                // Malformed Id string — will be treated as invalid in the loop
            }
        }
        Map<Id, User> ownerMap = new Map<Id, User>(
            [SELECT Id, IsActive FROM User WHERE Id IN :ruleOwnerIds]
        );

        // ── 4. Alert email recipients (once, before loop) ─────────────────────
        List<GroupMember> adminMembers = [
            SELECT UserOrGroupId, UserOrGroup.Name
            FROM GroupMember
            WHERE Group.DeveloperName = 'AccountAssignmentRule_Admins'
            AND Group.Type = 'Regular'
        ];
        List<String> alertEmails = new List<String>();
        if (!adminMembers.isEmpty()) {
            Set<Id> memberUserIds = new Set<Id>();
            for (GroupMember gm : adminMembers) {
                memberUserIds.add(gm.UserOrGroupId);
            }
            for (User u : [SELECT Id, Email FROM User WHERE Id IN :memberUserIds]) {
                if (String.isNotBlank(u.Email)) {
                    alertEmails.add(u.Email);
                }
            }
        }

        // ── 5. Main processing loop ───────────────────────────────────────────
        List<Account> toUpdate = new List<Account>();

        for (Account acc : filteredAccounts) {
            Boolean ruleApplied = false;

            for (Account_Assignment_Rule__mdt rule : rules) {

                // Skip catch-all rules
                if (isCatchAll(rule)) {
                    continue;
                }

                // Check geographic match
                if (!matches(rule, acc)) {
                    continue;
                }

                // Validate rule owner
                Id ruleOwnerId;
                try {
                    ruleOwnerId = Id.valueOf(rule.OwnerId__c);
                } catch (Exception e) {
                    sendInvalidOwnerAlert(String.valueOf(rule.Order__c), rule.OwnerId__c, alertEmails);
                    continue;
                }

                if (!ownerMap.containsKey(ruleOwnerId) || !ownerMap.get(ruleOwnerId).IsActive) {
                    sendInvalidOwnerAlert(String.valueOf(rule.Order__c), rule.OwnerId__c, alertEmails);
                    continue;
                }

                // Apply rule — build a new Account instance to avoid mutating
                // read-only Trigger.new records in after-insert context.
                Account toApply = new Account(Id = acc.Id, OwnerId = ruleOwnerId);
                if (String.isNotBlank(rule.Integration_Specialist__c)) {
                    try {
                        toApply.Integration_Specialist__c = Id.valueOf(rule.Integration_Specialist__c);
                    } catch (Exception e) {
                        // Malformed Id — leave field unchanged
                    }
                }
                if (String.isNotBlank(rule.Development_Specialist__c)) {
                    try {
                        toApply.Development_Specialist__c = Id.valueOf(rule.Development_Specialist__c);
                    } catch (Exception e) {
                        // Malformed Id — leave field unchanged
                    }
                }

                toUpdate.add(toApply);
                System.debug('se aplico la regla #' + rule.Order__c);
                ruleApplied = true;
                break; // first-match-wins
            }

            if (!ruleApplied) {
                System.debug('no cumplio con ninguna regla establecida');
            }
        }

        // ── 6. Single DML ─────────────────────────────────────────────────────
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // ─── Private Helpers ─────────────────────────────────────────────────────

    /**
     * Returns true if all geographic criteria on a rule are blank.
     * Such a rule would match every account — it is treated as a catch-all and skipped.
     */
    private static Boolean isCatchAll(Account_Assignment_Rule__mdt rule) {
        return String.isBlank(rule.BillingCountry__c)
            && String.isBlank(rule.BillingState__c)
            && String.isBlank(rule.BillingPostalCode__c);
    }

    /**
     * Evaluates whether an Account satisfies a rule's geographic criteria.
     *
     * Matching rules:
     * - Case-insensitive comparison.
     * - Blank rule field = wildcard (criterion is skipped / always passes).
     * - Country: comma-separated list — account country must appear in the list.
     * - State:   comma-separated list — account state must appear in the list.
     * - Postal:  comma-separated prefix list — account postal must startsWith any prefix.
     *
     * A rule matches only when ALL non-blank criteria pass.
     */
    private static Boolean matches(Account_Assignment_Rule__mdt rule, Account acc) {
        String accCountry = acc.BillingCountry != null ? acc.BillingCountry.toLowerCase().trim() : '';
        String accState   = acc.BillingState   != null ? acc.BillingState.toLowerCase().trim()   : '';
        String accPostal  = acc.BillingPostalCode != null ? acc.BillingPostalCode.toLowerCase().trim() : '';

        // Country check
        if (String.isNotBlank(rule.BillingCountry__c)) {
            Set<String> countryCriteria = new Set<String>();
            for (String part : rule.BillingCountry__c.split(',')) {
                countryCriteria.add(part.trim().toLowerCase());
            }
            if (!countryCriteria.contains(accCountry)) {
                return false;
            }
        }

        // State check
        if (String.isNotBlank(rule.BillingState__c)) {
            Set<String> stateCriteria = new Set<String>();
            for (String part : rule.BillingState__c.split(',')) {
                stateCriteria.add(part.trim().toLowerCase());
            }
            if (!stateCriteria.contains(accState)) {
                return false;
            }
        }

        // Postal Code prefix check
        if (String.isNotBlank(rule.BillingPostalCode__c)) {
            Boolean postalMatched = false;
            for (String part : rule.BillingPostalCode__c.split(',')) {
                String prefix = part.trim().toLowerCase();
                if (String.isNotBlank(prefix) && accPostal.startsWith(prefix)) {
                    postalMatched = true;
                    break;
                }
            }
            if (!postalMatched) {
                return false;
            }
        }

        return true;
    }

    /**
     * Sends an alert email to the AccountAssignmentRule_Admins group members
     * when a rule's OwnerId is invalid or inactive.
     *
     * In test context: suppressed when skipEmailInTest = true.
     *
     * @param ruleOrder   The Order__c value of the failing rule (for logging).
     * @param ownerId     The invalid OwnerId__c value from the rule.
     * @param alertEmails Pre-collected list of recipient email addresses.
     */
    @TestVisible
    private static void sendInvalidOwnerAlert(String ruleOrder, String ownerId, List<String> alertEmails) {
        System.debug('regla #' + ruleOrder + ' fallida — OwnerId inválido: ' + ownerId);

        if (Test.isRunningTest() && skipEmailInTest) {
            return;
        }

        if (alertEmails == null || alertEmails.isEmpty()) {
            return;
        }

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(alertEmails);
        mail.setSubject('Account Assignment Rule Error — Invalid Owner on Rule #' + ruleOrder);
        mail.setPlainTextBody(
            'Rule #' + ruleOrder + ' has an invalid or inactive OwnerId: ' + ownerId + '.\n'
            + 'Please review the Account_Assignment_Rule__mdt record and update the OwnerId.'
        );
        mail.setSaveAsActivity(false);

        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            System.debug('sendInvalidOwnerAlert failed: ' + e.getMessage());
        }
    }
}
