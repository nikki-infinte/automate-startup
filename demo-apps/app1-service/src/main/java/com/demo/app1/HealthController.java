package com.demo.app1;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.Map;

@RestController
public class HealthController {

    @Value("${spring.application.name:app1-service}")
    private String appName;

    @Value("${server.port:8081}")
    private String serverPort;

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

    @GetMapping("/api/hello")
    public Map<String, String> hello() {
        return Map.of("message", "Hello from " + appName + " on port " + serverPort);
    }
}
