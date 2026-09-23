import unittest
from types import SimpleNamespace
from unittest.mock import patch

from native_browser import recipe_task, recipe_evidence, NativeBrowser, run_recipe, safe_link, youtube_task, choose_youtube_video, run_youtube_video


class NativeBrowserTests(unittest.TestCase):
    def test_youtube_route_requires_explicit_video_request_and_keeps_browser_tab(self):
        plan=youtube_task('Open a new tab in Google Chrome and go to YouTube and find me a funny cat video')
        self.assertEqual(plan['outcome'],'youtube_video')
        self.assertTrue(plan['new_tab'])
        self.assertEqual(plan['browser'],'Google Chrome')
        self.assertIn('funny+cat+video',plan['url'])
        self.assertIsNone(youtube_task('Go to YouTube'))
        self.assertIsNone(youtube_task('Find me a funny cat video'))
        self.assertIsNone(youtube_task('Go to YouTube and find me a funny cat video then send it to Tom'))

    def test_youtube_result_is_observed_and_ranked_without_a_model(self):
        links=[
            {'id':'1','label':'A very serious dog','url':'https://www.youtube.com/watch?v=dog','ref':'dog'},
            {'id':'2','label':'Funny cats falling asleep','url':'https://www.youtube.com/watch?v=cat','ref':'cat'},
            {'id':'3','label':'Funny cat channel','url':'https://www.youtube.com/@cats','ref':'channel'},
        ]
        self.assertEqual(choose_youtube_video({'links':links},'funny cat video')['id'],'2')
        self.assertIsNone(choose_youtube_video({'links':[links[2]]},'funny cat video'))

    def test_youtube_runner_verifies_the_video_page(self):
        search={'url':'https://www.youtube.com/results?search_query=funny+cat+video','title':'YouTube','text':'',
                'links':[{'id':'2','label':'Funny cats','url':'https://www.youtube.com/watch?v=cat','ref':'cat'}], 'truncated':False}
        opened={'url':'https://www.youtube.com/watch?v=cat','title':'Funny cats','text':'', 'links':[], 'truncated':False}
        events=[]
        with patch('native_browser.NativeBrowser') as browser,patch('native_browser.target_point',return_value={'x':1,'y':2}),patch('typesafe_computer_use.macos.sleep_watching'):
            browser.return_value.observe.side_effect=[search,opened]
            result=run_youtube_video({'query':'funny cat video'},1,lambda:1,lambda event,**fields:events.append((event,fields)),lambda *a,**k:None)
        self.assertEqual(result['url'],opened['url'])
        self.assertEqual(browser.return_value.follow.call_args.args[1]['label'],'Funny cats')
        self.assertTrue(events[-1][1]['success'])
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
