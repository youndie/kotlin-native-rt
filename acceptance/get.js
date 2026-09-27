// A constant arrival rate of GETs at one URL: RATE per second for DURATION.
//   k6 run -e URL=http://127.0.0.1:18401/work -e RATE=100 -e DURATION=150s get.js
import http from "k6/http";
export const options = { scenarios: { s: {
  executor: "constant-arrival-rate", rate: parseInt(__ENV.RATE || "100"), timeUnit: "1s",
  duration: __ENV.DURATION || "150s", preAllocatedVUs: 60, maxVUs: 300,
} } };
export default function () { http.get(__ENV.URL); }
