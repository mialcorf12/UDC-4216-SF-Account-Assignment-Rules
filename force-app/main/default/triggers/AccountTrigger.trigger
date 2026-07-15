trigger AccountTrigger on Account (after insert, after update) {
    if (Trigger.isInsert) AccountTriggerHandler.handleAfterInsert(Trigger.new);
    if (Trigger.isUpdate) {
        AccountTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        AccountTriggerHandler.handleDynamicUpdate(Trigger.new, Trigger.oldMap);
    }
}