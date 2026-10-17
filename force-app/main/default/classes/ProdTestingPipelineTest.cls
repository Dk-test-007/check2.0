@isTest
private class ProdTestingPipelineTest {
    @isTest
    static void testConstructor() {
        ProdTestingPipeline instance = new ProdTestingPipeline();
        System.assertNotEquals(null, instance);
    }

}
