    # POC: GCP Application Load Balancer Monitoring with Grafana

    ## 1. Objective

    Monitor a GCP Application Load Balancer (ALB) in Grafana: golden signals (traffic, errors, latency, bandwidth) from **Cloud Monitoring**, and request and error logs from **Cloud Logging**.

    | Item | Value used in this POC |
    | --- | --- |
    | Project | `gcp-logs-510206` |
    | Load balancer | Global external ALB, URL map `zee-poc-alb` |
    | Backend service | `zee-backend-service` |
    | Grafana | v13.x |
    | Dashboard | GCP Application Load Balancer (30 panels) |

    ## 2. Architecture

    ```
    Client -> ALB (forwarding rule -> proxy -> URL map -> backend service -> VMs)
                |                                   |
                | metrics (automatic)               | request logs (must be enabled)
                v                                   v
        Cloud Monitoring                     Cloud Logging
                \                                   /
                \------ Service account key ------/
                                |
                            Grafana
                (2 datasources: Cloud Monitoring, Cloud Logging)
    ```

    ## 3. Prerequisites

    - Owner or Editor access to the GCP project (needed to enable APIs, create the service account and change the backend service).
    - A running Grafana instance with network access to `*.googleapis.com`.
    - The **Google Cloud Logging** datasource plugin installed in Grafana (Cloud Monitoring is built in).
    - `gcloud` CLI authenticated: `gcloud auth login`.

    ```bash
    export PROJECT_ID=gcp-logs-510206
    gcloud config set project $PROJECT_ID
    ```

    ## 4. Step 1: Enable the APIs

    | API | Why |
    | --- | --- |
    | Cloud Resource Manager | Lets Grafana list projects |
    | Cloud Monitoring | Reads ALB metrics |
    | Cloud Logging | Reads LB request logs |
    | Compute Engine | Reads LB and backend resources |

    ```bash
    gcloud services enable \
    cloudresourcemanager.googleapis.com \
    monitoring.googleapis.com \
    logging.googleapis.com \
    compute.googleapis.com
    ```

    Verify:

    ```bash
    gcloud services list --enabled | grep -E "cloudresourcemanager|monitoring|logging|compute"
    ```

    ## 5. Step 2: Create the service account and grant roles

    Use a read-only service account. Grafana only needs to read data.

    ```bash
    gcloud iam service-accounts create grafana-alb-monitor \
    --display-name="Grafana ALB monitoring (read-only)"

    SA=grafana-alb-monitor@${PROJECT_ID}.iam.gserviceaccount.com

    for ROLE in roles/monitoring.viewer roles/logging.viewer roles/compute.viewer; do
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA}" --role="$ROLE"
    done
    ```

    | Role | Purpose |
    | --- | --- |
    | `roles/monitoring.viewer` | Read metrics |
    | `roles/logging.viewer` | Read logs |
    | `roles/compute.viewer` | Read LB, backend and instance details |

    ## 6. Step 3: Create the service account key

    ```bash
    gcloud iam service-accounts keys create grafana-sa-key.json --iam-account=$SA
    ```

    - The command downloads a JSON key. Keep the file safe and never commit it to git.
    - If it fails with a policy error, the organization policy `iam.disableServiceAccountKeyCreation` is blocking keys. Ask the org admin for an exception, or use Workload Identity (see section 14).

    ## 7. Step 4: Enable logging on the backend service

    ALB request logs are **off by default**. Check the current state:

    ```bash
    gcloud compute backend-services describe zee-backend-service \
    --global --format="value(logConfig)"
    ```

    If it shows `enable=False`, turn it on:

    ```bash
    gcloud compute backend-services update zee-backend-service \
    --global --enable-logging --logging-sample-rate=1.0
    ```

    - Use `1.0` (100%) for the POC. For production, use a lower rate such as `0.1` to control cost.
    - Only requests made after this change are logged.

    ## 8. Step 5: Metrics need no setup

    ALB metrics are exported to Cloud Monitoring automatically under `loadbalancing.googleapis.com/https/...` (request count, latencies, bytes, frontend RTT). No agent or configuration is required. Data appears about 2 to 4 minutes after traffic.

    | Load balancer type | Metric prefix |
    | --- | --- |
    | Global external ALB (this POC) | `https/` |
    | Regional external ALB | `https/external/regional/` |
    | Internal ALB | `https/internal/` |

    ## 9. Step 6: Add the datasources in Grafana

    ### Cloud Monitoring

    1. **Connections -> Data sources -> Add data source -> Google Cloud Monitoring**.
    2. Name: `zee-poc`.
    3. Authentication: **Google JWT File**. Upload `grafana-sa-key.json`.
    4. Click **Save & test**. Expected: "Successfully queried the Google Cloud Monitoring API."

    ### Cloud Logging

    1. **Add data source -> Google Cloud Logging**.
    2. Name: `zee-poc-logs`.
    3. Authentication: **Google JWT File**. Upload the same key.
    4. Click **Save & test**.

    ## 10. Step 7: Import the dashboard

    1. **Dashboards -> New -> Import**, upload the dashboard JSON.
    2. In the top bar, select:

    | Variable | Value |
    | --- | --- |
    | Cloud Monitoring | `zee-poc` |
    | Cloud Logging | `zee-poc-logs` |
    | Project | `gcp-logs-510206` |
    | Load balancer (URL map) | `zee-poc-alb` |
    | Rate window | `5m` |

    3. Set the time range to **Last 1 hour** and click **Save dashboard** so the selections are kept.

    ### Panels included

    | Row | Panels |
    | --- | --- |
    | Overview | Request rate, availability, 5xx ratio, 4xx ratio, p95 total latency, p95 backend latency, response ratio by class, responses by code |
    | Traffic | Requests by status class, backend service, client country, protocol, forwarding rule |
    | Errors | 5xx ratio by backend, 5xx and 4xx by response code |
    | Latency | Total and backend percentiles, p95 by backend, frontend TCP RTT |
    | Bandwidth | Request and response throughput, egress by backend |
    | Logs | LB-generated errors, backend 5xx, Cloud Armor denies, config changes, all INFO requests |

## 12. Step 8: Validatedate

    Send test traffic to the ALB IP:

    ```bash
    while true; do
    for path in "/" "/does-not-exist"; do
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://<ALB_IP>$path")
        echo "$(date +%T) $path -> $code"
    done
    sleep 0.5
    done
    ```


    ## 13. Data storage and retention

    Grafana does not store metrics or logs. It is a viewer that queries Google live on every refresh. The time range on the dashboard only decides how much history is requested.

    | Data | Where it is stored | Retention | Can it be changed? |
    | --- | --- | --- | --- |
    | ALB metrics (request count, latency, bytes) | Cloud Monitoring | About 24 months | No |
    | LB request logs | Cloud Logging, `_Default` bucket | 30 days (default) | Yes, 1 to 3650 days |
    | Admin Activity audit logs (config changes) | Cloud Logging, `_Required` bucket | 400 days | No |
    | Dashboard JSON, variables, datasource settings | Grafana database | Until deleted | Back up in git |

    If Grafana is stopped or deleted, the metrics and logs stay safe in Google. Only the dashboard JSON needs a backup.

    ### Metrics

    - Stored and managed by Google at no charge, and nothing needs to be enabled.
    - Roughly the last 6 weeks are kept at 1-minute resolution. Older data is downsampled (about 10 minutes), so long ranges look smoother.
    - Retention cannot be extended in Cloud Monitoring. For longer history, export metrics to BigQuery or a Prometheus-compatible store (not needed for this POC).

    ### Logs: check and change retention

    Check the current setting:

    ```bash
    gcloud logging buckets describe _Default --location=global --project=gcp-logs-510206
    ```

    Extend it, for example to 90 days:

    ```bash
    gcloud logging buckets update _Default \
    --location=global --retention-days=90 --project=gcp-logs-510206
    ```

    Console path: **Logging -> Logs Storage -> `_Default` -> Edit bucket -> Retention period**.

    - A new retention value only applies to logs that have not expired yet. Logs already deleted do not come back.
    - The first 30 days of storage are free. Longer retention costs about $0.01 per GiB per month.
    - Each project gets roughly 50 GiB of free log ingestion per month. Beyond that it is charged, so 100% sampling on a busy ALB can become expensive.

    ### Keep only ALB logs for longer (cheaper)

    Create a dedicated bucket and route just the load balancer logs to it:

    ```bash
    gcloud logging buckets create alb-logs \
    --location=global --retention-days=90 --project=gcp-logs-510206

    gcloud logging sinks create alb-sink \
    logging.googleapis.com/projects/gcp-logs-510206/locations/global/buckets/alb-logs \
    --log-filter='resource.type="http_load_balancer"' \
    --project=gcp-logs-510206
    ```

    - The same logs also keep going to `_Default` unless an exclusion filter is added to the `_Default` sink.
    - To read from the new bucket in Grafana, select the bucket in the Cloud Logging query editor.

    ### Long-term archive (compliance or one year or more)

    Export logs to Cloud Storage (cheap, Coldline or Archive class) or BigQuery (SQL queries):

    ```bash
    gcloud logging sinks create alb-archive \
    storage.googleapis.com/<BUCKET_NAME> \
    --log-filter='resource.type="http_load_balancer"' \
    --project=gcp-logs-510206
    ```

    ## 14. Security and cost notes

    - **Least privilege:** the service account is read-only. Do not add editor or owner roles.
    - **Key handling:** store the JSON key in a secrets manager, rotate it every 90 days, and delete unused keys.
    - **Better than keys:** if Grafana runs on GCE or GKE, use the attached service account or Workload Identity and skip the key entirely.
    - **Logging cost:** 100% sampling logs every request. Lower the sample rate for production and set a log retention policy.
    - **Monitoring cost:** reading metrics through the API is free of per-query charges at this scale, but keep dashboard auto-refresh at 1 minute or slower.


