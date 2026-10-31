from pathlib import Path
import unittest


class SigningWorkflowTests(unittest.TestCase):
    def test_signed_workflow_is_manual_and_validates_authorized_identity(self):
        workflow = Path('.github/workflows/build-signed-ipa.yml')
        self.assertTrue(workflow.is_file())
        content = workflow.read_text()
        self.assertIn('workflow_dispatch:', content)
        self.assertIn('IOS_SIGNING_CERTIFICATE_BASE64', content)
        self.assertIn('IOS_PROVISIONING_PROFILE_BASE64', content)
        self.assertIn('io.corelo.ghostgpt', content)
        self.assertIn('codesign --verify --deep --strict', content)
        self.assertIn('always()', content)
        self.assertNotIn('Ecolab', content)


if __name__ == '__main__':
    unittest.main()
