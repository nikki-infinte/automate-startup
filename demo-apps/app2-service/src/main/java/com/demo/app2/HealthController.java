package com.demo.app2;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

import java.time.Instant;
import java.util.Map;

@RestController
public class HealthController {

    private final RestClient restClient;

    @Value("${spring.application.name:app2-service}")
    private String appName;

    @Value("${server.port:8082}")
    private String serverPort;

    public HealthController(@Value("${app1.base-url:http://localhost:8081}") String app1BaseUrl) {
        this.restClient = RestClient.builder().baseUrl(app1BaseUrl).build();
    }

    @GetMapping("/")
    public String home() {
        return appName + " is running on port " + serverPort;
    }

    @GetMapping("/api/health")
    public Map<String, Object> health() {
        return Map.of(
                "service", appName,
                "message", appName + " is running",
                "status", "UP",
                "port", serverPort,
                "timestamp", Instant.now().toString()
        );
    }

    @GetMapping("/api/check-app1")
    public Map<String, Object> checkUpstreamApp1() {
        Object app1Response = restClient.get()
                .uri("/api/health")
                .retrieve()
                .body(Map.class);
        return Map.of(
                "service", appName,
                "upstreamApp1", app1Response
        );
    }
}
