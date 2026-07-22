/**
 * AccountAssignmentRulesQueueable
 *
 * Defers AccountAssignmentRules.assign() to an async context.
 *
 * Lead Convert (Database.convertLead) runs the AccountTrigger synchronously
 * inside a restricted transaction where SELECT ... FROM User WHERE ProfileId
 * throws "No such column 'ProfileId' on entity 'User'". Queueable Apex
 * executes in a fresh context after that transaction commits, avoiding the
 * restriction, so the trigger enqueues this job instead of calling assign()
 * directly.
 */
public with sharing class AccountAssignmentRulesQueueable implements Queueable {

    private final Set<Id> accountIds;

    public AccountAssignmentRulesQueueable(Set<Id> accountIds) {
        this.accountIds = accountIds;
    }

    public void execute(QueueableContext context) {
        List<Account> accounts = [
            SELECT Id, OwnerId, BillingCountry, BillingState, BillingPostalCode
            FROM Account
            WHERE Id IN :accountIds
        ];
        AccountAssignmentRules.assign(accounts);
    }
}
