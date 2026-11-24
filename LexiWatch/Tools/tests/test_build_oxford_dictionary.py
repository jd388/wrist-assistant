import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import build_oxford_dictionary as oxford


class OxfordDictionaryBuildTests(unittest.TestCase):
    def test_chinese_reverse_keys_use_complete_gloss_segments(self):
        self.assertEqual(
            list(oxford.chinese_keys("（表示用法）照料；照顾，护理")),
            ["照料", "照顾", "护理"],
        )
        self.assertEqual(list(oxford.chinese_keys("A型；给予……帮助")), [])

    def test_patterns_variants_and_bilingual_collocations_survive_import(self):
        record = """
        <div><div class="t-oalecd10" data-hkoup-entry="test">
          <span class="t-h">make</span><span class="t-pos">verb</span>
          <div class="t-pron-gs">
            <span class="t-pron-g-blk"><span class="t-namelabel">NAmE</span><span class="t-phon">meɪk</span></span>
            <span class="t-pron-g-blk"><span class="t-brelabel">BrE</span><span class="t-phon">meɪk</span></span>
          </div>
          <div class="t-sn-g">
            <div class="t-def"><span class="t-chn">作出</span></div>
            <div class="t-x">
              <span class="t-cf"><span class="t-exp">~</span> a decision, guess, etc.</span>
              <span class="t-eng">She <span class="t-cl">made a choice</span>.</span>
              <span class="t-chn">她作出了选择。</span>
            </div>
          </div>
          <div class="t-sn-g">
            <div class="t-def"><span class="t-chn">制作</span></div>
          </div>
          <div class="t-pv-g">
            <span class="t-pv">ˌmake ˈdo with sth</span>
            <span class="t-v">manage with sth</span>
            <div class="t-sn-g">
              <div class="t-def"><span class="t-chn">将就着用</span></div>
            </div>
          </div>
        </div></div>
        """
        headword, phrase = list(oxford.parse_entries(record))
        _, pronunciations, meanings, _, related, examples, _, _ = headword
        self.assertEqual([(item["region"], item["ipa"]) for item in pronunciations], [
            ("us", "meɪk"), ("uk", "meɪk"),
        ])
        self.assertTrue(all(item["partOfSpeech"] == "verb" for item in pronunciations))
        self.assertIn("make a decision, guess, etc.", meanings[0]["collocations"])
        self.assertEqual(meanings[0]["collocationDetails"][0]["text"], "made a choice")
        self.assertEqual(meanings[0]["collocationDetails"][0]["exampleChinese"], "她作出了选择。")
        self.assertNotIn("collocationDetails", meanings[1])
        self.assertEqual(list(oxford.pattern_entries(meanings, "make"))[0][0], "make a decision")
        self.assertEqual(examples[0][0], "made a choice")
        self.assertEqual(examples[0][1]["exampleChinese"], "她作出了选择。")
        self.assertTrue(any(item["kind"] == "phrasalVerb" for item in related))
        self.assertEqual(related[0]["partOfSpeech"], "verb")
        self.assertIn("make do with", phrase[3])
        self.assertIn("manage with", phrase[3])

    def test_homograph_markers_are_metadata_and_literal_digits_survive(self):
        def record(spelling, gloss, part="verb"):
            return f"""
            <div><div class="t-oalecd10" data-hkoup-entry="test">
              <span class="t-h">{spelling}</span><span class="t-pos">{part}</span>
              <div class="t-sn-g">
                <div class="t-def"><span class="t-chn">{gloss}</span></div>
                <span class="t-cf">~ to sb</span>
              </div>
            </div></div>
            """.encode()

        first = 'lie<span class="t-homonym" hm="1"></span><span class="t-hm"><a>1</a></span>'
        second = 'lie<span class="t-homonym" hm="2"></span><span class="t-hm"><a>2</a></span>'
        entries = [
            (b"HKOUPLINKb", record(second, "说谎")),
            (b"HKOUPLINKa", record(first, "躺")),
            (b"MP3", record("MP3", "音频格式", "noun")),
            (b"H2O", record("H<sub>2</sub>O", "水", "noun")),
            (b"lied", b"@@@LINK=HKOUPLINKb"),
        ]

        class FakeMDX:
            def items(self):
                return entries

        with patch.object(oxford, "MDX", return_value=FakeMDX()):
            results, lookups, _ = oxford.read_entries(Path("fixture.mdx"))
        self.assertEqual([item["chinese"] for item in results["lie"]["meanings"]], ["躺", "说谎"])
        self.assertEqual(results["lie"]["meanings"][1]["collocations"], ["lie to sb"])
        self.assertEqual(set(results["lie"]["aliases"]), {"lie1", "lie2"})
        self.assertNotIn("lie1", results)
        self.assertEqual(lookups["lie1"], {"lie"})
        self.assertEqual(lookups["lied"], {"lie"})
        self.assertIn("MP3", results)
        self.assertIn("H2O", results)
