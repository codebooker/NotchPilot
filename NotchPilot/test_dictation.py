import sys
import unittest
from unittest.mock import patch,MagicMock
from dictation import dictated_text
from cua_agent import command_steps
from planner import Interpreter


class DictationTests(unittest.TestCase):
    def test_preserves_literal_pronouns_and_story_sentences(self):
        text='A little boy rode his bike. It was purple and had flames on it.'
        self.assertEqual(dictated_text('Write '+text),text)
        self.assertEqual(dictated_text('Please type exactly "I like this."'),'I like this.')
        self.assertEqual(dictated_text('Write “First then second.” into this document.'),'First then second.')
    def test_composition_and_compound_requests_stay_with_interpreter(self):
        for goal in ['Write a story about a boy','Write a short paragraph about cats','Write it in French',
                     'Type hello then open Finder','Write a letter to Tom','Do not write hello']:
            self.assertIsNone(dictated_text(goal),goal)
    def test_literal_then_is_not_a_stage_separator(self):
        goal='Write First we walked then we ate lunch.'
        self.assertEqual(command_steps(goal),[goal])
    def test_literal_request_bypasses_local_model_and_ambiguous_reference_guard(self):
        goal='Write A boy rode his bike. It was purple.'
        model=object.__new__(Interpreter)
        with patch.dict(sys.modules,{'mlx_lm':MagicMock(),'mlx_lm.sample_utils':MagicMock()}):
            result=model.interpret({'goal':goal},{'app':'TextEdit','window':'Untitled','document':'','focused_role':'AXTextArea'})
        self.assertEqual(result['action'],'execute')
        self.assertEqual(result['goal'],goal)
        self.assertEqual(result['seconds'],0)
