import json
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from pathlib import Path

from navigation import direct_navigation, normalize_url, navigate, address_field, press_key
from planner import validate_plan, validate_request


class NavigationTests(unittest.TestCase):
    def test_return_does_not_inherit_command_modifier(self):
        import Quartz
        with patch('Quartz.CGEventCreateKeyboardEvent',side_effect=lambda _,key,down:(key,down)), \
             patch('Quartz.CGEventSetFlags') as flags,patch('typesafe_computer_use.macos._post'):
            press_key('return')
            self.assertEqual([call.args[1] for call in flags.call_args_list],[0,0])
            flags.reset_mock();press_key('a',True)
            self.assertEqual([call.args[1] for call in flags.call_args_list],[Quartz.kCGEventFlagMaskCommand,0])
    def test_natural_literal_addresses(self):
        for goal in ['Go to example.com', 'Open Safari and go to example.com',
                     'Could you go to example dot com in Safari please?',
                     'In Safari, visit https://example.com/', 'Open example.com in Safari.']:
            result=direct_navigation(goal)
            self.assertIsNotNone(result,goal)
            self.assertEqual(result['url'],'https://example.com/')
        self.assertEqual(direct_navigation('Go to example.com')['browser'],None)
        self.assertEqual(direct_navigation('Open example.com in Safari')['browser'],'Safari')
        self.assertEqual(normalize_url('example.com/CaseSensitive?q=Hello'),'https://example.com/CaseSensitive?q=Hello')

    def test_no_guessed_urls_or_dropped_steps(self):
        for goal in ['Do not open example.com', 'Go to example.com and delete my account',
                     'Go to example.com then open Finder', 'Open report.txt', 'Go to example.com or example.org',
                     'Go to javascript:example.com', 'Open file:///example.com', 'Open https://user:pass@example.com']:
            self.assertIsNone(direct_navigation(goal),goal)
        self.assertIsNone(direct_navigation('Go to invented.com','Go to example.com'))
        self.assertIsNone(direct_navigation('Go to example.com/other','Go to example.com/original'))

    def test_planner_url_validation_allows_scheme_but_not_invented_host(self):
        req=validate_request({'goal':'Go to example dot com/CaseSensitive'})
        plan=lambda goal: json.dumps(dict(action='execute',goal=goal,question=''))
        validate_plan(plan('Go to https://example.com/CaseSensitive'),req,{})
        for goal in ['Go to https://invented.com/', 'Go to https://example.com/Other', 'Open invented.txt']:
            with self.assertRaises(ValueError):validate_plan(plan(goal),req,{})

    def test_navigation_verifies_page_not_just_address_bar(self):
        field=SimpleNamespace(value='https://example.com/')
        with patch('navigation.address_field',return_value=True),patch('navigation.browser_url',return_value='https://example.com/'), \
             patch('typesafe_computer_use.macos.focused_field',return_value=field), \
             patch('typesafe_computer_use.macos.check_abort'),patch('navigation.press_key') as press, \
             patch('typesafe_computer_use.actions.fill_field') as fill:
            self.assertTrue(navigate('example.com',1,lambda:1))
            self.assertEqual(press.call_args_list[0].args,('l',True))
            self.assertEqual(press.call_args_list[-1].args,('return',))
            fill.assert_called_once_with(field,'https://example.com/')
            with self.assertRaisesRegex(RuntimeError,'active app changed'):navigate('example.com',1,lambda:2)

    def test_wrong_field_never_submits(self):
        field=SimpleNamespace(value='different text')
        with patch('navigation.address_field',return_value=True),patch('typesafe_computer_use.macos.focused_field',return_value=field), \
             patch('typesafe_computer_use.macos.check_abort'),patch('navigation.press_key') as press, \
             patch('typesafe_computer_use.actions.fill_field'):
            with self.assertRaisesRegex(RuntimeError,'did not retain'):navigate('example.com',1,lambda:1)
            press.assert_called_once_with('l',True)

    def test_page_search_field_is_not_address_bar(self):
        field=SimpleNamespace(is_text=True,label='Search',placeholder='',ref='field')
        attrs={('field','AXRole'):'AXTextField',('field','AXParent'):'page',('page','AXRole'):'AXWebArea'}
        with patch('typesafe_computer_use.macos._ax_attr',side_effect=lambda node,key:attrs.get((node,key))):
            self.assertFalse(address_field(field))

    def test_direct_worker_needs_no_api_and_preview_never_acts(self):
        import AppKit
        from worker import run
        app=SimpleNamespace(localizedName=lambda:'Safari',processIdentifier=lambda:123)
        workspace=SimpleNamespace(sharedWorkspace=lambda:SimpleNamespace(frontmostApplication=lambda:app))
        with patch('worker.front_app',return_value=('Safari',123)),patch.object(AppKit,'NSWorkspace',workspace),patch('Quartz.CGPreflightScreenCaptureAccess',return_value=True), \
             patch('typesafe_computer_use.macos.accessibility_trusted',return_value=True), \
             patch('worker.handshake'),patch('worker.emit') as emit,patch('worker.subprocess.run') as opened, \
             patch('worker.navigate',return_value=True) as nav,patch('worker.API') as api:
            run(Path('/unused'),'Go to example.com in Safari',preview=True)
            opened.assert_not_called();nav.assert_not_called();api.assert_not_called()
            run(Path('/unused'),'Go to example.com in Safari')
            self.assertTrue(emit.call_args.kwargs['success'])
            self.assertEqual(emit.call_args.kwargs['cost'],0)
            api.assert_not_called();nav.assert_called_once()


if __name__=='__main__':unittest.main()
