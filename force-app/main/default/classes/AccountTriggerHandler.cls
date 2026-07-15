/**
 * Handles Account trigger events and delegates to OrgEventPublisher.
 *
 * Filtering logic:
 * - After insert:  publishes for Accounts already in a qualifying Onboarding_Status__c
 *                  with UDC_Onboarding__c = true.
 * - After update:  publishes only when Onboarding_Status__c transitions to a qualifying
 *                  status (Approved / Rejected) AND UDC_Onboarding__c = true.
 *
 * Bulkification: both handlers process collections; SOQL and DML happen inside
 * OrgEventPublisher, never in loops here.
 */
public with sharing class AccountTriggerHandler {

    /**
     * Called from AccountTrigger on after insert.
     * Publishes events for new Accounts already in a qualifying Onboarding_Status__c
     * with UDC_Onboarding__c = true.
     *
     * @param newAccounts  Trigger.new — the inserted Account records.
     */
    public static void handleAfterInsert(List<Account> newAccounts) {
        List<Account> qualifying = new List<Account>();
        for (Account acc : newAccounts) {
            if (acc.UDC_Onboarding__c == true
                    && OrgEventPublisherConfig.QUALIFYING_STATUSES.contains(acc.Onboarding_Status__c)) {
                qualifying.add(acc);
            }
        }
        if (!qualifying.isEmpty()) {
            OrgEventPublisher.publishEvents(qualifying, null);
        }
    }

    /**
     * Called from AccountTrigger on after update.
     * Publishes events only when Onboarding_Status__c changes to a qualifying status
     * (Approved / Rejected) AND UDC_Onboarding__c = true.
     *
     * @param newAccounts  Trigger.new — the updated Account records (new values).
     * @param oldMap       Trigger.oldMap — the pre-update Account values keyed by Id.
     */
    public static void handleAfterUpdate(List<Account> newAccounts, Map<Id, Account> oldMap) {
        List<Account> qualifying = new List<Account>();
        for (Account acc : newAccounts) {
            Account oldAcc = oldMap.get(acc.Id);
            Boolean statusChanged = (oldAcc != null)
                && (acc.Onboarding_Status__c != oldAcc.Onboarding_Status__c);
            if (acc.UDC_Onboarding__c == true
                    && statusChanged
                    && OrgEventPublisherConfig.QUALIFYING_STATUSES.contains(acc.Onboarding_Status__c)) {
                qualifying.add(acc);
            }
        }
        if (!qualifying.isEmpty()) {
            OrgEventPublisher.publishEvents(qualifying, oldMap);
        }
    }

    /**
     * Called from AccountTrigger on after update (dynamic field-change path).
     * Delegates to FieldMappingService which evaluates old-vs-new field deltas using
     * Event_Field_Mapping__mdt CMT records and publishes sfdc_account_updated__e
     * Platform Events for any mapped field changes.
     *
     * This method runs alongside handleAfterUpdate (UDC-3865) without interference.
     *
     * @param newRecords  Trigger.new — the updated Account records (new values).
     * @param oldMap      Trigger.oldMap — the pre-update Account values keyed by Id.
     */
    public static void handleDynamicUpdate(
        List<Account> newRecords,
        Map<Id, Account> oldMap
    ) {
        if (newRecords == null || newRecords.isEmpty()) {
            return;
        }
        FieldMappingService.publishAccountEvents(newRecords, oldMap);
    }
}