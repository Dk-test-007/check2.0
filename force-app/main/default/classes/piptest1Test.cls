@isTest
private class piptest1Test {
  @isTest
  static void testConstructor() {
    piptest1 instance = new piptest1();
    System.assertNotEquals(null, instance);
  }
}
