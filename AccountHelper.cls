/*****************************************************
 * @Description : This Class is used for the Vat Functionality verification.
 *****************************************************/
public with sharing class AccountHelper {
    /**
    * Going through all Accounts from accountIdSet and calling EU SOAP request for VAT Number.
    * Write response to VAT_Number_Validation_Status__c picklist field
    */
    @Future(callout=true)
    public static void checkVAT(Set<Id> accountIdSet) {
        List<Account> accountList = [select VAT_Number__c, 
                                        CODAECCountryCode__c, EC_Country_Code__c,
                                        VAT_Number_Validation_Status__c
                                        from Account
                                        where Id in :accountIdSet];
        CheckVATTypes.checkVatResponse_element vatResponse = new CheckVATTypes.checkVatResponse_element();
        CheckVAT.checkVatPort vatSOAP = new CheckVAT.checkVatPort();
        
        system.debug('accounts: ' + accountList);
        for (Account acc : accountList) {
            // Since there are CODAECCountryCode__c and EC_Country_Code__c which contain same values, I will test them both
            // for values but EC_Country_Code__c is primary
            String ecCountryCode;
            if (acc.EC_Country_Code__c != null) {
                ecCountryCode = acc.EC_Country_Code__c;
            } 
            else if (acc.CODAECCountryCode__c != null) {
                ecCountryCode = acc.CODAECCountryCode__c;
            }
            
            system.debug('SOAP parameters ' + ecCountryCode + ' ' + acc.VAT_Number__c.remove(' '));
            vatResponse = vatSOAP.checkVat(ecCountryCode, acc.VAT_Number__c.remove(' '));
            system.debug('+++++vatResponse: ' + vatResponse);
            
            if (vatResponse.valid) {
                acc.VAT_Number_Validation_Status__c = 'Valid';
            }
            else {
                acc.VAT_Number_Validation_Status__c = 'Not Valid';
            }
        }
        update accountList;
    }
}