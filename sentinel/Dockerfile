FROM eclipse-temurin:17.0.14_7-jre-jammy
ARG SENTINEL_VERSION=1.8.10
WORKDIR /app
ADD https://github.com/alibaba/Sentinel/releases/download/${SENTINEL_VERSION}/sentinel-dashboard-${SENTINEL_VERSION}.jar /app/dashboard.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/dashboard.jar"]
