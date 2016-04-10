#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""augur-core unit tests

Unit tests for data and api/comments.se.

@author Jack Peterson (jack@tinybike.net)

"""
import sys
import os
import json
import unittest
import iocapture
from ethereum import tester

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, os.pardir))

from contract import ContractTest

class TestComments(ContractTest):

    def setUp(self):
        ContractTest.setUp(self, "functions", "comments.se")
        self.event_fields = {"commentID", "message", "_event_type",
                             "market", "parent", "block", "author"}
        self.params = {
            "speak": {
                "market": 0xdeadbeef,
                "author": 0x05ae1d0ca6206c6168b42efcd1fbe0ed144e821b,
                "message": "why hello, world!  could I interest you in a comment?",
            },
            "reply": {
                "market": 0xdeadbeef,
                "author": 0x639b41c4d3d399894f2a57894278e1653e7cd24c,
                "message": "world: no thx, comments make me violently ill",
            },
        }

    def test_speak(self):
        with iocapture.capture() as captured:
            retval = self.contract.speak(self.params["speak"]["market"],
                                         self.params["speak"]["author"],
                                         self.params["speak"]["message"])
            output = json.loads(captured.stdout.replace("'", '"')
                                               .replace("L", "")
                                               .replace('u"', '"'))
        assert(retval == 1)
        assert(set(output.keys()) == self.event_fields)
        for k in self.params["speak"]:
            assert(output[k] == self.params["speak"][k])

    def test_reply(self):
        with iocapture.capture() as captured:
            self.contract.speak(self.params["speak"]["market"],
                                self.params["speak"]["author"],
                                self.params["speak"]["message"])
            output = json.loads(captured.stdout.replace("'", '"')
                                               .replace("L", "")
                                               .replace('u"', '"'))
        self.params["reply"]["parent"] = output["commentID"]
        with iocapture.capture() as captured:
            retval = self.contract.reply(self.params["reply"]["market"],
                                         self.params["reply"]["author"],
                                         self.params["reply"]["parent"],
                                         self.params["reply"]["message"])
            reply_output = json.loads(captured.stdout.replace("'", '"')
                                                     .replace("L", "")
                                                     .replace('u"', '"'))
        assert(retval == 1)
        assert(set(reply_output.keys()) == self.event_fields)
        for k in self.params["reply"]:
            assert(reply_output[k] == self.params["reply"][k])
        assert(reply_output["parent"] == self.params["reply"]["parent"])


if __name__ == "__main__":
    suite = unittest.TestLoader().loadTestsFromTestCase(TestComments)
    unittest.TextTestRunner(verbosity=2).run(suite)
