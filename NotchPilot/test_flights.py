import base64
from datetime import date
import unittest
from flights import prepare_flight, verify_flights

GOAL='Open a new tab in Google Chrome and find me a flight from Orlando to London Heathrow Airport'


class FlightTests(unittest.TestCase):
    def test_missing_dates_asks_instead_of_claiming_search_success(self):
        result=prepare_flight({'goal':GOAL},date(2026,9,21))
        self.assertEqual(result['action'],'clarify');self.assertEqual(result['goal'],'')

    def test_relative_dates_and_route_survive_clarification(self):
        result=prepare_flight({'goal':GOAL,'dialogue':[{'question':'Dates?','answer':'depart today return tomorrow I guess'}]},date(2026,9,21))
        self.assertEqual(result['flight'],dict(origin='Orlando',destination='London Heathrow Airport',departure='2026-09-21',return_date='2026-09-22',adults=1,cabin='economy'))
        self.assertIn('returning 2026-09-22',result['goal'])

    def test_verifies_each_requirement_and_observed_fares(self):
        spec=prepare_flight({'goal':GOAL+' departing 2026-09-21 returning 2026-09-22'},date(2026,9,21))['flight']
        payload=base64.urlsafe_b64encode(b'2026-09-21 2026-09-22').decode()
        values={'Where from?':'Orlando','Where to?':'London Heathrow','Departure':'Mon, Sep 21','Return':'Tue, Sep 22',
                'Change ticket type. Round trip':'Round trip','Change cabin class. Economy':'Economy','1 passenger':'1'}
        page={'url':'https://www.google.com/travel/flights/search?tfs='+payload,'actions':[{'label':k,'value':v} for k,v in values.items()]+[{'label':'From 750 US dollars. Nonstop flight with Example Airline. Leaves Orlando at 6:00 PM on Monday, September 21 and arrives at Heathrow Airport at 7:00 AM. Select flight'}]}
        self.assertTrue(verify_flights(page,spec)['passed'])
        page['actions'][1]['value']='London'
        self.assertFalse(verify_flights(page,spec)['passed'],'London alone must not satisfy Heathrow')
        page['actions'][1]['value']='London Heathrow';page['actions'][3]['value']='Wed, Sep 23'
        self.assertFalse(verify_flights(page,spec)['passed'])
        page['actions'][3]['value']='Tue, Sep 22';page['url']='https://www.google.com/search?q=flights'
        self.assertFalse(verify_flights(page,spec)['passed'])


if __name__=='__main__':unittest.main()
