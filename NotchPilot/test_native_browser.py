import unittest
from types import SimpleNamespace
from unittest.mock import patch

from native_browser import recipe_task, recipe_evidence, NativeBrowser, run_recipe, safe_link


class NativeBrowserTests(unittest.TestCase):
    def test_route_preserves_qualifiers_and_compound_boundary(self):
        goal='Open a new tab in Google Chrome and find me a gluten free recipe for apple strudel'
        plan=recipe_task(goal)
        self.assertEqual(plan['goal'],goal)
        self.assertTrue(plan['new_tab'])
        self.assertIn('gluten free',plan['query'])
        self.assertIsNotNone(recipe_task('Find me a recipe for apple strudel'))
        for goal in ('Find my recipe file','Delete a recipe','Find a recipe and send it to Tom','Do not find a recipe'):
            self.assertIsNone(recipe_task(goal),goal)

    def test_real_content_required_not_headings_or_search_snippets(self):
        content='Ingredients\n2 cups flour\n1 tablespoon butter\nInstructions\nMix flour. Add butter. Roll and bake.'
        self.assertTrue(recipe_evidence(dict(url='https://example.com/strudel',text=content)))
        self.assertFalse(recipe_evidence(dict(url='https://www.google.com/search?q=strudel',text=content)))
        self.assertFalse(recipe_evidence(dict(url='https://example.com/strudel',text='Ingredients\nInstructions\nSubscribe now')))
        self.assertIsNone(safe_link('javascript:alert(1)'))
        self.assertIsNone(safe_link('https://user:password@example.com'))

    def test_changed_link_stops_before_navigation(self):
        browser=object.__new__(NativeBrowser)
        browser.pid=1;browser.front_pid=lambda:1;browser.check=lambda *a:None
        with patch('typesafe_computer_use.macos._ax_attr',return_value='https://other.example/'),patch('native_browser.navigate') as navigate:
            with self.assertRaisesRegex(RuntimeError,'link changed'):
                browser.follow({'url':'https://example.com/'},{'ref':'node','url':'https://example.com/recipe'})
            navigate.assert_not_called()

    def test_search_cannot_offer_done_and_uses_no_debug_transport(self):
        page=dict(url='https://www.google.com/search?q=recipe',title='Search',text='Ingredients\nInstructions',links=[],truncated=False)
        api=SimpleNamespace(cost=0)
        def call(body):
            self.assertNotIn('done',body['questions']['next']['criteria'])
            return {'answers':{'next':{'choice':'blocked','confidence':1}}}
        api.call=call
        events=[]
        with patch('native_browser.NativeBrowser') as browser,patch('typesafe_computer_use.macos.sleep_watching'):
            browser.return_value.observe.return_value=page
            result=run_recipe({'goal':'Find a recipe'},1,lambda:1,api,lambda e,**kw:events.append((e,kw)),lambda *a,**k:None)
        self.assertIsNone(result)
        self.assertFalse(events[-1][1]['success'])

    def test_notification_handler_never_grants_or_handles_other_permissions(self):
        from navigation import dismiss_notification_prompt
        def attr(node,key):
            return {('app','AXWindows'):['window'],('window','AXChildren'):['allow','block'],
                    ('allow','AXRole'):'AXButton',('block','AXRole'):'AXButton'}.get((node,key))
        labels={'window':'example.com wants to: Show notifications','allow':'Allow','block':'Block'}
        with patch('ApplicationServices.AXUIElementCreateApplication',return_value='app'), \
             patch('ApplicationServices.AXUIElementSetMessagingTimeout'),patch('typesafe_computer_use.macos._ax_attr',side_effect=attr), \
             patch('typesafe_computer_use.macos._ax_label',side_effect=lambda node:labels.get(node,'')), \
             patch('typesafe_computer_use.macos.ax_press',return_value=True) as press:
            self.assertTrue(dismiss_notification_prompt(123));press.assert_called_once_with('block')
            press.reset_mock();labels['window']='example.com wants to: Use your camera'
            self.assertFalse(dismiss_notification_prompt(123));press.assert_not_called()


if __name__=='__main__':unittest.main()
