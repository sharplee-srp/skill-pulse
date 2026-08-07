import json
import os
import unittest
from contextlib import redirect_stdout
from io import StringIO
from unittest import mock

import hermes_tweet_backend as backend


class HermesTweetBackendTests(unittest.TestCase):
    def test_build_headers_supports_x_api_key(self):
        self.assertEqual(backend.build_headers("xq_test")["x-api-key"], "xq_test")

    def test_build_headers_supports_bearer_token(self):
        self.assertEqual(backend.build_headers("token")["Authorization"], "Bearer token")

    def test_build_url_encodes_query(self):
        with mock.patch.dict(os.environ, {"XQUIK_BASE_URL": "https://xquik.test"}):
            url = backend.build_url("/api/v1/x/tweets/search", {"q": "openclaw skill", "limit": 2})
        self.assertEqual(url, "https://xquik.test/api/v1/x/tweets/search?q=openclaw+skill&limit=2")

    def test_extract_items_reads_nested_data(self):
        payload = {"data": {"tweets": [{"id": "1"}, {"id": "2"}]}}
        self.assertEqual(backend.extract_items(payload), [{"id": "1"}, {"id": "2"}])

    def test_normalize_tweet_matches_track_shape(self):
        tweet = backend.normalize_tweet(
            {
                "id": "42",
                "text": "Hermes Tweet can feed skill-pulse.",
                "author": {"username": "alice", "name": "Alice"},
                "public_metrics": {"like_count": 9, "retweet_count": 2, "view_count": 30},
            }
        )
        self.assertEqual(tweet["id"], "42")
        self.assertEqual(tweet["author"]["username"], "alice")
        self.assertEqual(tweet["likeCount"], 9)
        self.assertEqual(tweet["retweetCount"], 2)
        self.assertEqual(tweet["viewCount"], 30)

    def test_cli_fails_closed_to_empty_list(self):
        with mock.patch.object(backend, "search_tweets", side_effect=backend.HermesTweetError("missing")):
            stdout = StringIO()
            with redirect_stdout(stdout):
                code = backend.main(["hermes_tweet_backend.py", "search", "ai skill", "5"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout.getvalue()), [])


if __name__ == "__main__":
    unittest.main()
