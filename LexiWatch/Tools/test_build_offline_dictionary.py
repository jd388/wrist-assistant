import unittest

import build_offline_dictionary as builder


def row(translation: str, pos: str = "") -> dict[str, str]:
    return {"translation": translation, "pos": pos}


class BuildOfflineDictionaryCleaningTests(unittest.TestCase):
    def test_removes_broken_pronunciation_variant_marker(self) -> None:
        self.assertEqual(
            builder.cleaned_pronunciation("bɔnɔ'mi:; (?@) bɔnә'mi:"),
            "bɔnɔ'mi:; bɔnә'mi:",
        )

    def test_exchange_metadata_never_becomes_an_alias(self) -> None:
        self.assertEqual(
            builder.aliases(
                "0:abandon/1:dp/p:abandoned/d:abandoned/i:abandoning/3:abandons",
                "abandoned",
            ),
            ["abandon", "abandoning", "abandons"],
        )
        self.assertEqual(
            builder.aliases("s:djs/i:djing/p:djed/f:DJs", "DJ"),
            ["djs", "djing", "djed"],
        )
        self.assertEqual(
            builder.aliases("0:p/1:s/s:pps", "PP"),
            ["pps"],
        )

    def test_splits_legacy_translation_into_structured_parts_of_speech(self) -> None:
        meanings = builder.structured_meanings(
            row("n. 问题, 难题\\na. 成问题的, 难处理的")
        )

        self.assertEqual(
            [(item["partOfSpeech"], item["chinese"]) for item in meanings],
            [("n.", "问题, 难题"), ("adj.", "成问题的, 难处理的")],
        )

    def test_part_of_speech_prefix_requires_a_real_token_boundary(self) -> None:
        abbreviation = builder.structured_meanings(
            row("abbr. 面向对象程式设计（Object Oriented）")
        )
        ordinary_english_prefix = builder.structured_meanings(
            row("apple pie 苹果派")
        )

        self.assertEqual(
            [(item["partOfSpeech"], item["chinese"]) for item in abbreviation],
            [("abbr.", "面向对象程式设计（Object Oriented）")],
        )
        self.assertEqual(
            [(item["partOfSpeech"], item["chinese"]) for item in ordinary_english_prefix],
            [("", "apple pie 苹果派")],
        )

    def test_drops_only_sense_with_irrecoverable_ocr_replacement(self) -> None:
        meanings = builder.structured_meanings(
            row("a. 委婉的, 迂回的, 冗长的\\n[医] \ue7ab嗦话的, 赘语的")
        )

        self.assertEqual(len(meanings), 1)
        self.assertEqual(meanings[0]["chinese"], "委婉的, 迂回的, 冗长的")

    def test_rejects_entry_when_every_sense_is_irrecoverably_damaged(self) -> None:
        self.assertEqual(builder.structured_meanings(row("[医] ╂Т")), [])
        self.assertEqual(builder.structured_meanings(row("na. 【动】笑NE16F")), [])

    def test_recovers_markup_without_leaving_watch_glyph_artifacts(self) -> None:
        meanings = builder.structured_meanings(
            row("v. 零乱<X>零乱<DDX>vt. 塞满■堆满")
        )
        rendered = str(meanings[0]["chinese"])

        self.assertNotIn("<X>", rendered)
        self.assertNotIn("<DDX>", rendered)
        self.assertNotIn("■", rendered)
        self.assertIn("零乱", rendered)
        self.assertIn("堆满", rendered)

    def test_repairs_mixed_or_unpaired_delimiters_deterministically(self) -> None:
        casa = builder.structured_meanings(
            row(
                "n. 天文学高级研究中心（；计算机与自动化系统（Computer and "
                "Automated System Association）；合作应用卫星A（Cooperative "
                "Application Satellite A）"
            )
        )
        eaton = builder.structured_meanings(row("n. 伊顿（姓氏））"))
        willi = builder.structured_meanings(row("n. 威利(人名）"))

        self.assertEqual(
            casa[0]["chinese"],
            "天文学高级研究中心；计算机与自动化系统（Computer and Automated "
            "System Association）；合作应用卫星A（Cooperative Application Satellite A）",
        )
        self.assertEqual(eaton[0]["chinese"], "伊顿（姓氏）")
        self.assertEqual(willi[0]["chinese"], "威利(人名)")

    def test_drops_metadata_only_senses_without_substantive_chinese(self) -> None:
        for translation in (
            "vi. [ 不用于进行时和被动语态 ]",
            "v. [正式用语]",
            "aux. [will的过去式] modal v",
        ):
            self.assertEqual(builder.structured_meanings(row(translation)), [])

    def test_keeps_chinese_inside_a_meaningful_grammar_annotation(self) -> None:
        meanings = builder.structured_meanings(
            row("adv. [far 的比较级]（空间距离）")
        )

        self.assertEqual(meanings[0]["chinese"], "[far 的比较级]（空间距离）")

    def test_quarantines_network_labeled_senses_without_losing_clean_senses(self) -> None:
        meanings = builder.structured_meanings(
            row("n. 可靠释义\\n[网络] 错误抓取；垃圾释义")
        )

        self.assertEqual(
            [meaning["chinese"] for meaning in meanings],
            ["可靠释义"],
        )
        self.assertEqual(builder.structured_meanings(row("[网络] 受害者")), [])
        self.assertEqual(builder.chinese_keywords("[网络] 受害者"), [])

    def test_rejects_inflection_pointer_without_a_chinese_gloss(self) -> None:
        self.assertEqual(
            builder.structured_meanings(row("tantalising的变形")),
            [],
        )
        self.assertEqual(builder.chinese_keywords("tantalising的变形"), [])

    def test_reverse_keywords_exclude_bracketed_domain_metadata(self) -> None:
        self.assertEqual(
            builder.chinese_keywords(
                "[医] 多香果；[化] 香料成分；(法)称呼；磁通(量)计"
            ),
            ["多香果", "香料成分", "称呼", "磁通", "量"],
        )

    def test_removes_dangling_colons_inside_a_compound_gloss(self) -> None:
        meanings = builder.structured_meanings(row("v. 做:；举办；公布:"))

        self.assertEqual(meanings[0]["chinese"], "做；举办；公布")


if __name__ == "__main__":
    unittest.main()
