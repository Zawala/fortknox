package fortknox.zw.ratelimit;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "rate-limit")
public class RateLimitProperties {

    /** Maximum number of requests allowed per window. */
    private int capacity = 50;

    /** Number of tokens refilled per window (usually same as capacity). */
    private int refillAmount = 50;

    /** Refill window duration in seconds. */
    private int refillPeriodSeconds = 60;

    public int getCapacity() { return capacity; }
    public void setCapacity(int capacity) { this.capacity = capacity; }

    public int getRefillAmount() { return refillAmount; }
    public void setRefillAmount(int refillAmount) { this.refillAmount = refillAmount; }

    public int getRefillPeriodSeconds() { return refillPeriodSeconds; }
    public void setRefillPeriodSeconds(int refillPeriodSeconds) { this.refillPeriodSeconds = refillPeriodSeconds; }
}
