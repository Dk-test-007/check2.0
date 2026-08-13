@isTest
public with sharing class test2Test {
  @isTest
  public test2Test() {
    test2 instance = new test2();
    System.assertNotEquals(null, instance);
  }
}
