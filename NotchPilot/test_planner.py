import json
import unittest
from planner import validate_plan,validate_request,introduces_object


class PlanValidationTests(unittest.TestCase):
    def test_references_can_use_objects_introduced_in_same_request(self):
        for prefix in ['Create a new document, type into ', 'Open /tmp/test.txt and save ', 'Open notes.txt and edit ']:
            self.assertTrue(introduces_object(prefix))
        for prefix in ['Open ', 'In TextEdit, edit ', 'Make ']:
            self.assertFalse(introduces_object(prefix))

    def test_malformed_and_mixed_clarifications_never_execute(self):
        request=validate_request({'goal':'Open Finder'})
        for text in ['{"action":"execute"', 'Here is the result: {}',
                     json.dumps({'action':'execute','goal':'Open Finder','question':'Which app?'}),
                     json.dumps({'action':'clarify','goal':'Open Finder','question':'Which app?'})]:
            with self.assertRaises(ValueError):validate_plan(text,request,{})

    def test_invented_paths_and_added_actions_are_rejected(self):
        request=validate_request({'goal':'Open my notes'})
        for goal in ['Open /Users/fake/secret.txt','Delete notes','Send notes to someone','Grant permission to Finder']:
            with self.assertRaises(ValueError):validate_plan(json.dumps({'action':'execute','goal':goal,'question':''}),request,{})

    def test_explicit_user_clarification_supplies_authority(self):
        request=validate_request({'goal':'Do something with this file','dialogue':[{'question':'What action?','answer':'Delete notes.txt'}]})
        plan=validate_plan(json.dumps({'action':'execute','goal':'Delete notes.txt','question':''}),request,{})
        self.assertEqual(plan['action'],'execute')

    def test_context_and_clarification_limits(self):
        with self.assertRaises(ValueError):validate_request({'goal':'go','context':['a']*7})
        with self.assertRaises(ValueError):validate_request({'goal':'go','dialogue':[{'question':'x','answer':'y'}]*4})


if __name__=='__main__':unittest.main()
