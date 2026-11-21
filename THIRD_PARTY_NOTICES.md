# Third-party notices

The generated offline dictionary is derived from
[ECDICT](https://github.com/skywind3000/ECDICT), commit
`bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b`.

ECDICT is distributed under the MIT License:

Copyright (c) 2025 Linwei

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Local translation models

The Chinese-to-English Core ML encoder and decoder are converted from
[`Helsinki-NLP/opus-mt_tiny_zho-eng`](https://huggingface.co/Helsinki-NLP/opus-mt_tiny_zho-eng),
revision `4ee3a9342aae4ca6fbae82c930b5dccff5dd68dd`.

The English-to-Chinese Core ML encoder and decoder are converted and
8-bit weight-palettized from
[`Helsinki-NLP/opus-mt-en-zh`](https://huggingface.co/Helsinki-NLP/opus-mt-en-zh),
revision `408d9bc410a388e1d9aef112a2daba955b945255`.

Both source repositories declare the Apache License 2.0. The license text is
available at <https://www.apache.org/licenses/LICENSE-2.0>. The bundled
SentencePiece-derived tokenizer resources correspond exactly to these model
revisions and are used only for local inference.

## English Speller Database coverage list

The broad offline headword and inflection coverage manifest is generated from
[English Speller Database (ESDB)](https://wordlist.aspell.net/), source commit
`1e5b7d3a72f47a71da5d28686c1dd4b397178485`. LexiWatch uses the size-70
American/British spelling set with variant level 1, excludes abbreviations and
capitalized proper-name lemmas, and imports no ESDB definitions. Chinese
definitions continue to come from the ECDICT pipeline described above.

Copyright 2000-2026 by Kevin Atkinson

Permission to use, copy, modify, distribute, and sell any part of the English
Speller Database (ESDB, previously known as SCOWLv2), or word lists created
from it, is hereby granted without fee, provided that the above copyright
notice appears in all copies and that both the above copyright notice and this
notice appear in supporting documentation. Kevin Atkinson makes no
representations about the suitability of this database for any purpose. It is
provided "as is" without express or implied warranty.
