import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
from pathlib import Path
from types import SimpleNamespace
from navigation import browser_task, new_browser_tab, search_result_matches, browser_address_field
from worker import execute_browser_task, run, front_app

FLIGHT='Open a new tab in Google Chrome and find me a flight from Orlando to London Heathrow Airport'


class BrowserTaskTests(unittest.TestCase):
    def test_address_lookup_ignores_web_page_search_fields(self):
        attrs={('app','AXFocusedWindow'):'window',('window','AXRole'):'AXWindow',('window','AXChildren'):['web','address'],
               ('web','AXRole'):'AXWebArea',('web','AXChildren'):['impostor'],
               ('address','AXRole'):'AXTextField',('address','AXDescription'):'Address and search bar',('address','AXParent'):'window',
               ('address','AXValue'):'https://example.com/',('impostor','AXRole'):'AXTextField',('impostor','AXDescription'):'Address and search bar'}
        with patch('ApplicationServices.AXUIElementCreateApplication',return_value='app'),patch('ApplicationServices.AXUIElementSetMessagingTimeout'), \
             patch('typesafe_computer_use.macos._ax_attr',side_effect=lambda node,key:attrs.get((node,key))), \
             patch('typesafe_computer_use.macos._ax_frame',return_value=(1,2,30,40)):
            field=browser_address_field(123)
            self.assertEqual(field.ref,'address')
            self.assertEqual(field.value,'https://example.com/')
    def test_foreground_check_uses_accessibility_when_workspace_is_unavailable(self):
        import AppKit
        app=SimpleNamespace(localizedName=lambda:'Google Chrome',processIdentifier=lambda:123)
        running=SimpleNamespace(runningApplicationWithProcessIdentifier_=lambda pid:app if pid==123 else None)
        workspace=SimpleNamespace(sharedWorkspace=lambda:SimpleNamespace(frontmostApplication=lambda:None))
        with patch('typesafe_computer_use.macos._ax_attr',return_value='focused'), \
             patch('ApplicationServices.AXUIElementGetPid',return_value=(0,123)),patch.object(AppKit,'NSRunningApplication',running),patch.object(AppKit,'NSWorkspace',workspace):
            self.assertEqual(front_app(),('Google Chrome',123))
        workspace=SimpleNamespace(sharedWorkspace=lambda:SimpleNamespace(frontmostApplication=lambda:None))
        with patch('typesafe_computer_use.macos._ax_attr',return_value=None),patch.object(AppKit,'NSWorkspace',workspace):
            with self.assertRaisesRegex(RuntimeError,'Accessibility'):front_app()

    def test_foreground_read_pumps_workspace_notifications(self):
        import AppKit
        app=SimpleNamespace(localizedName=lambda:'Google Chrome',processIdentifier=lambda:123,isActive=lambda:True)
        workspace=SimpleNamespace(sharedWorkspace=lambda:SimpleNamespace(frontmostApplication=lambda:app))
        with patch('typesafe_computer_use.macos._ax_attr',return_value=None),patch.object(AppKit,'NSWorkspace',workspace), \
             patch('Foundation.NSRunLoop') as loop:
            self.assertEqual(front_app(),('Google Chrome',123))
            loop.currentRunLoop.return_value.runUntilDate_.assert_called_once()

    def test_preserves_whole_request_without_inventing_dates(self):
        plan=browser_task(FLIGHT)
        self.assertTrue(plan['new_tab']);self.assertEqual(plan['browser'],'Google Chrome')
        self.assertEqual(plan['query'],'a flight from Orlando to London Heathrow Airport')
        self.assertEqual(parse_qs(urlsplit(plan['url']).query),{'q':[plan['query']]})
        self.assertIsNone(browser_task('Open a new tab in Chrome and find flights and book the cheapest'))
        self.assertIsNone(browser_task('Open a new tab in Chrome and search for flights then compare fares'))
        self.assertIsNone(browser_task('Do not open a new tab in Chrome'))
        self.assertIsNone(browser_task('Find my notes.txt'))

    def test_generic_queries_urls_and_tab_only(self):
        self.assertEqual(browser_task('Open a new tab in Chrome')['browser'],'Google Chrome')
        self.assertIsNone(browser_task('Open a new tab in Chrome')['query'])
        self.assertEqual(browser_task('Open a new tab in Safari and go to example.com')['url'],'https://example.com/')
        self.assertEqual(browser_task('Search for research and development in Chrome')['query'],'research and development')
        self.assertEqual(browser_task('Open a new tab in Chrome, then search for Swift actor isolation')['query'],'Swift actor isolation')
        self.assertIsNone(browser_task('Open a new tab in Chrome and go to example.com in Safari'))

    def test_exactly_one_tab_in_same_window(self):
        before={'window':'existing','count':3}
        with patch('navigation.browser_tabs',side_effect=[before,{'window':'existing','count':4}]), \
             patch('navigation.new_tab_button',return_value=None),patch('navigation.press_key') as key,patch('typesafe_computer_use.macos.check_abort'):
            new_browser_tab(123,lambda:123)
            key.assert_called_once_with('t',True)
        with patch('navigation.browser_tabs',side_effect=[before]+[{'window':'different','count':4}]*20), \
             patch('navigation.new_tab_button',return_value=None),patch('navigation.press_key'),patch('typesafe_computer_use.macos.check_abort'),patch('typesafe_computer_use.macos.sleep_watching'):
            with self.assertRaisesRegex(RuntimeError,'existing window'):new_browser_tab(123,lambda:123)

    def test_native_new_tab_action_preferred(self):
        with patch('navigation.browser_tabs',side_effect=[{'window':'w','count':3},{'window':'w','count':4}]), \
             patch('navigation.new_tab_button',return_value='button'),patch('typesafe_computer_use.macos.ax_press',return_value=True) as press, \
             patch('navigation.press_key') as key,patch('typesafe_computer_use.macos.check_abort'):
            new_browser_tab(123,lambda:123)
            press.assert_called_once_with('button');key.assert_not_called()

    def test_search_verification_accepts_tracking_but_not_wrong_query_or_consent(self):
        query='Orlando to London Heathrow Airport'
        self.assertTrue(search_result_matches('https://www.google.com/search?q=Orlando+to+London+Heathrow+Airport&source=hp',query))
        for url in ['https://www.google.com/search?q=other','https://consent.google.com/search?q=Orlando+to+London+Heathrow+Airport','https://evil.example/search?q=Orlando+to+London+Heathrow+Airport']:
            self.assertFalse(search_result_matches(url,query))

    def test_tab_then_search_and_only_then_completion(self):
        order=[];catalog={'0':{'name':'Google Chrome','path':'/Applications/Google Chrome.app'}}
        with patch('worker.handshake'),patch('worker.activate_browser',side_effect=lambda *a:order.append('activate') or 123), \
             patch('worker.new_browser_tab',side_effect=lambda *a:order.append('tab')), \
             patch('worker.navigate',side_effect=lambda *a,**kw:order.append('search') or True), \
             patch('worker.emit',side_effect=lambda event,**kw:order.append('done') if event=='done' else None):
            execute_browser_task(browser_task(FLIGHT),catalog,lambda:('Google Chrome',123))
        self.assertEqual(order,['activate','tab','search','done'])

    def test_preview_and_unverified_search_do_not_claim_success(self):
        catalog={'0':{'name':'Google Chrome','path':'/Applications/Google Chrome.app'}}
        with patch('worker.handshake'),patch('worker.activate_browser',return_value=123) as activate, \
             patch('worker.new_browser_tab'),patch('worker.navigate',return_value=False),patch('worker.emit') as emit:
            execute_browser_task(browser_task(FLIGHT),catalog,lambda:('Google Chrome',123),True)
            activate.assert_not_called();self.assertFalse(emit.call_args.kwargs['success'])
            execute_browser_task(browser_task(FLIGHT),catalog,lambda:('Google Chrome',123))
            self.assertFalse(emit.call_args.kwargs['success'])

    def test_worker_uses_original_request_even_if_model_dropped_search(self):
        import AppKit
        app=SimpleNamespace(localizedName=lambda:'Google Chrome',processIdentifier=lambda:123)
        workspace=SimpleNamespace(sharedWorkspace=lambda:SimpleNamespace(frontmostApplication=lambda:app))
        with patch('worker.front_app',return_value=('Google Chrome',123)),patch.object(AppKit,'NSWorkspace',workspace),patch('Quartz.CGPreflightScreenCaptureAccess',return_value=True), \
             patch('typesafe_computer_use.macos.accessibility_trusted',return_value=True), \
             patch('worker.execute_browser_task') as execute,patch('worker.open_exact_app') as opened,patch('worker.API') as api:
            with self.assertRaisesRegex(RuntimeError,'date details'):
                run(Path('/unused'),'Open Google Chrome',authorization=FLIGHT)
            execute.assert_not_called()
            opened.assert_not_called();api.assert_not_called()


if __name__=='__main__':unittest.main()
