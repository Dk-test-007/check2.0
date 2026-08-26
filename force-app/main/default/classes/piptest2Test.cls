@isTest
private class piptest2Test {
  @isTest
  static void testConstructor() {
    piptest2 instance = new piptest2();
    System.assertNotEquals(null, instance);
  }
}
